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
import { ADMIN_ACCOUNTANT_ROLE, ADMIN_UNPAUSER_ROLE, LPT_LP_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoBlacklist } from "../../../src/interfaces/IRoycoBlacklist.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoLiquidityProviderTranche } from "../../../src/interfaces/IRoycoLiquidityProviderTranche.sol";
import { IRoycoSeniorTranche } from "../../../src/interfaces/IRoycoSeniorTranche.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../../../src/interfaces/IYDM.sol";
import { MAX_TRANCHE_UNITS, WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../../src/libraries/Constants.sol";
import { AssetClaims, MarketState, Operation, SyncedAccountingState, TrancheType } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { DispatchLogic } from "../../../src/libraries/logic/DispatchLogic.sol";
import { IKernelTestHooks } from "../../utils/IKernelTestHooks.sol";
import { RoycoDayTestBase } from "../../utils/RoycoDayTestBase.sol";

/**
 * @title Test_KernelSuiteBase
 * @notice The shared, config-driven base every Day kernel test extends. `setUp` reads the concrete kernel's `TestConfig`,
 *         forks the configured network, deploys the market end-to-end through the real `DeployScript` (via the concrete
 *         `_deployKernelAndMarket` hook, which selects a market config by name from the config file), wires every deployed
 *         contract into member vars (including the Day-only LPT/pool/hook/LDM topology the script's result omits), and
 *         funds the ST/JT providers. Concrete kernel tests then only supply the per-kernel `IKernelTestHooks` and the market
 *         name, following an "abstract kernel test per kernel type" pattern.
 * @dev The shared tests live here on top of the scaffolding, grouped by flow: deposits, redemptions, syncs, adversarial.
 */
abstract contract Test_KernelSuiteBase is RoycoDayTestBase, IKernelTestHooks {
    /// @notice The concrete kernel's static test configuration (assets, fork, funding).
    TestConfig internal testConfig;

    /// @notice The single coinvested collateral asset backing both ST and JT (== `KERNEL.COLLATERAL_ASSET()`).
    address internal COLLATERAL_ASSET;

    // ── Day market-topology addresses the script's `DeploymentResult` does not surface ──
    /// @notice The liquidity provider tranche (holds the Gyro E-CLP BPT).
    IRoycoVaultTranche internal LPT;
    /// @notice The liquidity provider tranche's Gyro E-CLP pool (the BPT, == `KERNEL.LPT_ASSET()`).
    address internal POOL;
    /// @notice The pool's kernel-bound hook (the upgraded `RoycoDayBalancerV3Hooks` proxy).
    address internal BALANCER_HOOK;
    /// @notice The liquidity-premium model (LDM), distinct from the JT YDM.
    address internal LPT_YDM;
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

        // The coinvestment collapse leaves one collateral asset, so the config's two hook assets must be it
        COLLATERAL_ASSET = KERNEL.COLLATERAL_ASSET();
        assertEq(testConfig.stAsset, COLLATERAL_ASSET, "setup: the configured ST asset must be the kernel's collateral asset");
        assertEq(testConfig.jtAsset, COLLATERAL_ASSET, "setup: the configured JT asset must be the kernel's collateral asset");

        // Capture the Day LPT topology the script result omits, by reading the deployed contracts.
        if (testConfig.hasLiquidityProviderTranche) {
            LPT = IRoycoVaultTranche(KERNEL.LIQUIDITY_PROVIDER_TRANCHE());
            POOL = KERNEL.LPT_ASSET();
            LPT_YDM = ACCOUNTANT.getState().lptYDM;
            VAULT = IVault(address(GyroECLPPoolFactory(DEPLOY_SCRIPT.getChainConfig(block.chainid, false).gyroECLPPoolFactory).getVault()));
            BALANCER_HOOK = VAULT.getHooksConfig(POOL).hooksContract;
            vm.label(address(LPT), "LPT");
            vm.label(POOL, "BalancerPool");
            vm.label(BALANCER_HOOK, "BalancerHook");
            vm.label(LPT_YDM, "LDM");
        }

        _setupProviders();
        _fundAllProviders();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REUSABLE HELPERS (used by future tests)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deals each provider the ST/JT (and, if the market has an LPT, the quote) asset with `initialFunding`.
    function _fundAllProviders() internal {
        for (uint256 i = 0; i < providers.length; ++i) {
            _fundActor(providers[i]);
        }
    }

    /// @notice Deposits `_amount` (asset units) of the collateral asset from `_lp` into the senior tranche, returning the shares.
    function _depositST(address _lp, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_lp);
        IERC20(COLLATERAL_ASSET).approve(address(ST), _amount);
        shares = ST.deposit(toTrancheUnits(_amount), _lp);
        vm.stopPrank();
    }

    /// @notice Deposits `_amount` (asset units) of the collateral asset from `_lp` into the junior tranche, returning the shares.
    function _depositJT(address _lp, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_lp);
        IERC20(COLLATERAL_ASSET).approve(address(JT), _amount);
        shares = JT.deposit(toTrancheUnits(_amount), _lp);
        vm.stopPrank();
    }

    /// @notice Asserts single-collateral NAV conservation on the LIVE view marks within the kernel's NAV tolerance.
    /// @dev ST and JT raw NAVs are both the whole coinvested collateral NAV by design, so their equality is
    ///      asserted wei-exact first. Committed-checkpoint conservation is wei-exact and asserted via
    ///      `_assertCommittedConservation` instead.
    /// @notice The live collateral NAV through the production pricing path (the kernel's collateral ledger valued by its pricing path)
    function _liveCollateralNAV() internal view returns (NAV_UNIT) {
        return KERNEL.convertCollateralAssetsToValue(KERNEL.getState().totalCollateralAssets);
    }

    /// @notice The live LPT raw NAV through the production pricing path (the kernel's LPT ledger valued by its pricing path)
    function _liveLPTRawNAV() internal view returns (NAV_UNIT) {
        return KERNEL.convertLPTAssetsToValue(KERNEL.getState().totalLPTAssets);
    }

    function _assertNAVConservation() internal view {
        NAV_UNIT collateralNAV = _liveCollateralNAV();
        NAV_UNIT stEffectiveNAV = ST.totalAssets().nav;
        NAV_UNIT jtEffectiveNAV = JT.totalAssets().nav;
        assertApproxEqAbs(collateralNAV, stEffectiveNAV + jtEffectiveNAV, maxNAVDelta(), "NAV conservation");
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
        uint256 lptShares;
    }

    /**
     * @notice Full market snapshot. Every mutating test diffs pre vs post against independently
     *         computed expectations.
     * @dev Utilizations are recomputed from the committed checkpoint fields via the pure recompute helpers,
     *      never by re-calling an accountant view, so gate assertions stay independent.
     */
    struct MarketSnapshot {
        // Live raw NAVs (pricing conversions of owned assets). lptRawNAV is 0 when the market has no LPT
        NAV_UNIT collateralNAV;
        NAV_UNIT lptRawNAV;
        // Committed accountant checkpoint (ACCOUNTANT.getState())
        NAV_UNIT lastCollateralNAV;
        NAV_UNIT lastLPTRawNAV;
        NAV_UNIT lastSTEffectiveNAV;
        NAV_UNIT lastJTEffectiveNAV;
        NAV_UNIT lastJTImpermanentLoss;
        MarketState marketState;
        uint32 fixedTermEnd;
        uint32 lastAccrualTs;
        uint32 lastPremiumTs;
        uint128 twJT;
        uint128 twLPT;
        // Utilizations recomputed live from committed inputs via _expectedCoverageUtilization/_expectedLiquidityUtilization
        uint256 coverageUtilizationWAD;
        uint256 liquidityUtilizationWAD;
        // Supplies
        uint256 stSupply;
        uint256 jtSupply;
        uint256 lptSupply;
        // Kernel owned-asset accounting (KERNEL.getState())
        TRANCHE_UNIT collateralOwned;
        TRANCHE_UNIT lptOwned;
        uint256 lptOwnedSeniorTrancheShares;
        // Kernel token balances (solvency side)
        uint256 kernelCollateralBal;
        uint256 kernelBPTBal;
        uint256 kernelSTShareBal;
        // Fee recipient share balances
        uint256 feeRecipientSTShares;
        uint256 feeRecipientJTShares;
        uint256 feeRecipientLPTShares;
        ActorShares[] actors;
    }

    /// @notice Captures a full market snapshot plus the per-actor share balances for `_actors`.
    function _snap(address[] memory _actors) internal view returns (MarketSnapshot memory s) {
        bool hasLPT = testConfig.hasLiquidityProviderTranche;

        // Live raw NAVs through the production pricing path
        s.collateralNAV = _liveCollateralNAV();
        if (hasLPT) s.lptRawNAV = _liveLPTRawNAV();

        // Committed accountant checkpoint
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        s.lastCollateralNAV = a.lastCollateralNAV;
        s.lastLPTRawNAV = a.lastLPTRawNAV;
        s.lastSTEffectiveNAV = a.lastSTEffectiveNAV;
        s.lastJTEffectiveNAV = a.lastJTEffectiveNAV;
        s.lastJTImpermanentLoss = a.lastJTImpermanentLoss;
        s.marketState = a.lastMarketState;
        s.fixedTermEnd = a.fixedTermEndTimestamp;
        s.lastAccrualTs = a.lastYieldShareAccrualTimestamp;
        s.lastPremiumTs = a.lastPremiumPaymentTimestamp;
        s.twJT = a.twJTYieldShareAccruedWAD;
        s.twLPT = a.twLPTYieldShareAccruedWAD;

        // Utilizations recomputed independently from the committed checkpoint
        s.coverageUtilizationWAD = _expectedCoverageUtilization(a.lastCollateralNAV, a.minCoverageWAD, a.lastJTEffectiveNAV);
        s.liquidityUtilizationWAD = _expectedLiquidityUtilization(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLPTRawNAV);

        // Supplies
        s.stSupply = ST.totalSupply();
        s.jtSupply = JT.totalSupply();
        if (hasLPT) s.lptSupply = LPT.totalSupply();

        // Kernel owned-asset ledger
        IRoycoDayKernel.RoycoDayKernelState memory k = KERNEL.getState();
        s.collateralOwned = k.totalCollateralAssets;
        s.lptOwned = k.totalLPTAssets;
        s.lptOwnedSeniorTrancheShares = k.lptOwnedSeniorTrancheShares;

        // Kernel token balances (solvency side)
        s.kernelCollateralBal = IERC20(COLLATERAL_ASSET).balanceOf(address(KERNEL));
        if (hasLPT) {
            s.kernelBPTBal = IERC20(POOL).balanceOf(address(KERNEL));
            s.kernelSTShareBal = ST.balanceOf(address(KERNEL));
        }

        // Fee recipient share balances
        s.feeRecipientSTShares = ST.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);
        s.feeRecipientJTShares = JT.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);
        if (hasLPT) s.feeRecipientLPTShares = LPT.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);

        // Per-actor share balances
        s.actors = new ActorShares[](_actors.length);
        for (uint256 i = 0; i < _actors.length; ++i) {
            s.actors[i] = ActorShares({
                actor: _actors[i], stShares: ST.balanceOf(_actors[i]), jtShares: JT.balanceOf(_actors[i]), lptShares: hasLPT ? LPT.balanceOf(_actors[i]) : 0
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
        assertGe(
            IERC20(COLLATERAL_ASSET).balanceOf(address(KERNEL)), toUint256(k.totalCollateralAssets), "solvency: collateral balance below the owned-asset ledger"
        );
        if (testConfig.hasLiquidityProviderTranche) {
            assertGe(IERC20(POOL).balanceOf(address(KERNEL)), toUint256(k.totalLPTAssets), "solvency: BPT balance below the owned-asset ledger");
            assertGe(ST.balanceOf(address(KERNEL)), k.lptOwnedSeniorTrancheShares, "solvency: ST share balance below the idle liquidity premium ledger");
        }
    }

    /// @notice Wei-exact conservation on the COMMITTED checkpoint: `collateralNAV == stEff + jtEff` holds
    ///         byte-for-byte, because the waterfall only ever re-labels value between the two tranches.
    /// @dev Also asserts the state-machine biconditional: every PERPETUAL commit erases the IL and a
    ///      FIXED_TERM commit always retains a nonzero IL, so PERPETUAL iff no impermanent loss.
    function _assertCommittedConservation() internal view {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertNAVConservation(a.lastCollateralNAV, a.lastSTEffectiveNAV, a.lastJTEffectiveNAV, "committed checkpoint");
        assertTrue(
            (a.lastMarketState == MarketState.PERPETUAL) == (a.lastJTImpermanentLoss == ZERO_NAV_UNITS), "state machine: PERPETUAL iff no impermanent loss"
        );
    }

    // ── Actors, roles, gating ──

    /// @notice The two LPT liquidity providers, lazily created by `_setupLPTProviders`.
    address internal LPT_ALICE_ADDRESS;
    address internal LPT_BOB_ADDRESS;

    /// @dev Monotonic nonce so every `_randomOutsider` address is unique within a test.
    uint256 private _outsiderNonce;

    /// @notice Skips the test when the market has no liquidity provider tranche.
    modifier whenLPT() {
        if (!testConfig.hasLiquidityProviderTranche) vm.skip(true);
        _;
    }

    /// @notice Lazily creates + funds the two LPT providers with `LPT_LP_ROLE` (idempotent).
    function _setupLPTProviders() internal {
        if (LPT_ALICE_ADDRESS == address(0)) {
            LPT_ALICE_ADDRESS = _generateProvider("LPT_ALICE", LPT_LP_ROLE).addr;
            _fundActor(LPT_ALICE_ADDRESS);
        }
        if (LPT_BOB_ADDRESS == address(0)) {
            LPT_BOB_ADDRESS = _generateProvider("LPT_BOB", LPT_LP_ROLE).addr;
            _fundActor(LPT_BOB_ADDRESS);
        }
    }

    /// @notice Returns a fresh role-less address funded with every market asset.
    function _randomOutsider() internal returns (address outsider) {
        outsider = makeAddr(string.concat("OUTSIDER_", vm.toString(_outsiderNonce++)));
        _fundActor(outsider);
    }

    /// @dev Funds an actor with `initialFunding` of the ST/JT (and, when the market has an LPT, the quote) asset.
    function _fundActor(address _actor) private {
        dealSTAsset(_actor, testConfig.initialFunding);
        dealJTAsset(_actor, testConfig.initialFunding);
        if (testConfig.hasLiquidityProviderTranche) dealQuoteAsset(_actor, testConfig.initialFunding);
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

    /// @dev The OZ ERC4626 virtual-shares/value offset (Constants.sol VIRTUAL_SHARES / VIRTUAL_VALUE): every
    ///      non-fresh share conversion prices against the effective supply (supply + 1e6) over the effective
    ///      value (totalValue + 1). Restated here (not imported) so a silent src change diverges loudly
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_VALUE = 1;

    /// @notice Expected shares minted for `_value` against `_supply` shares backed by `_totalNAV` (floor).
    /// @dev Mirrors `ValuationLogic._convertToShares` including its fresh-tranche exemption, the virtual
    ///      shares/value offset, and the mint-dilution clamp (bind iff
    ///      value·(WAD − MAX_MINT_DILUTION) > denominator·MAX_MINT_DILUTION, products fit on the suite domain).
    function _expectedShares(NAV_UNIT _value, uint256 _supply, NAV_UNIT _totalNAV) internal pure returns (uint256) {
        // A genuinely fresh tranche (no shares AND no backing) mints 1:1, every other state prices through the offset
        if (_supply == 0 && toUint256(_totalNAV) == 0) return toUint256(_value);
        uint256 effectiveSupply = _supply + VIRTUAL_SHARES;
        uint256 denominator = toUint256(_totalNAV) + VIRTUAL_VALUE;
        if (toUint256(_value) * (WAD - MAX_MINT_DILUTION) > denominator * MAX_MINT_DILUTION) {
            return Math.mulDiv(effectiveSupply, MAX_MINT_DILUTION, WAD - MAX_MINT_DILUTION);
        }
        return Math.mulDiv(toUint256(_value), effectiveSupply, denominator);
    }

    /// @notice Expected value redeemed for `_shares` against `_supply` shares backed by `_totalNAV` (floor).
    /// @dev Mirrors `ValuationLogic._convertToValue` including its fresh-tranche exemption and the offset.
    function _expectedValue(uint256 _shares, uint256 _supply, NAV_UNIT _totalNAV) internal pure returns (NAV_UNIT) {
        if (_supply == 0 && toUint256(_totalNAV) == 0) return toNAVUnits(uint256(0));
        return toNAVUnits(Math.mulDiv(toUint256(_totalNAV) + VIRTUAL_VALUE, _shares, _supply + VIRTUAL_SHARES));
    }

    /// @notice Independent coverage utilization recomputation (ceil), mirroring `UtilizationLogic._computeCoverageUtilization`.
    function _expectedCoverageUtilization(NAV_UNIT _collateralNAV, uint64 _minCoverageWAD, NAV_UNIT _jtEffectiveNAV) internal pure returns (uint256) {
        if (_minCoverageWAD == 0 || toUint256(_collateralNAV) == 0) return 0;
        if (toUint256(_jtEffectiveNAV) == 0) return type(uint256).max;
        return Math.mulDiv(toUint256(_collateralNAV), _minCoverageWAD, toUint256(_jtEffectiveNAV), Math.Rounding.Ceil);
    }

    /// @notice Independent liquidity utilization recomputation (ceil), mirroring `UtilizationLogic._computeLiquidityUtilization`.
    function _expectedLiquidityUtilization(NAV_UNIT _stEffectiveNAV, uint64 _minLiquidityWAD, NAV_UNIT _lptRawNAV) internal pure returns (uint256) {
        if (toUint256(_stEffectiveNAV) == 0 || _minLiquidityWAD == 0) return 0;
        if (toUint256(_lptRawNAV) == 0) return type(uint256).max;
        return Math.mulDiv(toUint256(_stEffectiveNAV), _minLiquidityWAD, toUint256(_lptRawNAV), Math.Rounding.Ceil);
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
     * @notice Input/output packet for the independent single-collateral tranche accounting sync recomputation.
     * @dev Inputs are the committed checkpoint, the MEASURED post-simulate collateral NAV, the premium-window
     *      inputs (the stored time-weighted accumulators plus this sync's YDM previews weighted by the
     *      accrual window), the fee rates, and the dust tolerance. Outputs are every committed field the
     *      sync produces, filled in by `_expectedSync`.
     */
    struct SyncExpectation {
        // Inputs: measured collateral NAV + committed checkpoint
        NAV_UNIT collateralNAVNew;
        NAV_UNIT lastCollateralNAV;
        NAV_UNIT lastSTEffectiveNAV;
        NAV_UNIT lastJTEffectiveNAV;
        NAV_UNIT lastJTImpermanentLoss;
        // Inputs: the premium window (yield shares capped at the max* config, accumulators as stored)
        uint256 jtYieldShareWAD;
        uint256 lptYieldShareWAD;
        uint256 twJTStart;
        uint256 twLPTStart;
        uint256 elapsed;
        uint256 premiumElapsed;
        // Inputs: fee rates and dust
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 jtYieldShareProtocolFeeWAD;
        uint64 lptYieldShareProtocolFeeWAD;
        NAV_UNIT dustTolerance;
        // Input: whether the resulting market state zeroes the LPT premium and all fees
        bool fixedTermActive;
        // Outputs
        NAV_UNIT stEffectiveNAV;
        NAV_UNIT jtEffectiveNAV;
        NAV_UNIT jtImpermanentLoss;
        NAV_UNIT lptLiquidityPremium;
        NAV_UNIT stProtocolFee;
        NAV_UNIT jtProtocolFee;
        NAV_UNIT lptProtocolFee;
        NAV_UNIT jtRiskPremium;
        bool premiumsPaid;
    }

    /**
     * @notice Re-derives the full tranche accounting sync from the written accounting rules, independently of production code.
     * @dev Mirrors `RoycoDayAccountant._previewSyncTrancheAccounting`: a collateral gain repays the JT
     *      impermanent loss off the top (`min(gain, IL)`, restoration, never fee'd, re-anchoring the
     *      attribution basis to the restored claims), then the residual gain splits to ST pro-rata to its
     *      effective NAV claim (floor) with JT taking the residual so it absorbs the rounding drift, the JT
     *      residual with the dust-gated JT fee, and premiums
     *      `floor(stGain * (twStart + yieldShare * elapsed) / (premiumElapsed * WAD))`, the time-weighted
     *      average yield share over the full window since the last premium payment, which reduces to
     *      `floor(stGain * yieldShare / WAD)` for a single constant-share window, with the same-block
     *      (`premiumElapsed == 0`) instantaneous-share path, fee floors, `premiumsPaid = stGain > dust` gating
     *      every fee, and the LPT premium folded back into stEffectiveNAV. A collateral loss is absorbed
     *      junior-first (`min(loss, jtEffectiveNAV)` booked to the impermanent loss) with only the uncovered
     *      residual reaching ST.
     *      One collateral asset at one rate means a loss never splits and only a gain is attributed pro-rata,
     *      so mixed-sign tranche PnL is unrepresentable here.
     */
    function _expectedSync(SyncExpectation memory _e) internal pure returns (SyncExpectation memory) {
        uint256 stEffectiveNAV = toUint256(_e.lastSTEffectiveNAV);
        uint256 jtEffectiveNAV = toUint256(_e.lastJTEffectiveNAV);
        uint256 jtImpermanentLoss = toUint256(_e.lastJTImpermanentLoss);
        uint256 dust = toUint256(_e.dustTolerance);

        uint256 jtProtocolFee;
        uint256 lptLiquidityPremium;
        uint256 stProtocolFee;
        uint256 lptProtocolFee;
        uint256 jtRiskPremium;
        bool premiumsPaid;
        uint256 collateralNAVNew = toUint256(_e.collateralNAVNew);
        uint256 lastCollateralNAV = toUint256(_e.lastCollateralNAV);
        if (collateralNAVNew > lastCollateralNAV) {
            // STEP_REPAY_JT_IMPERMANENT_LOSS: the drawdown is repaid off the top of the gain, re-anchoring the basis
            uint256 gain = collateralNAVNew - lastCollateralNAV;
            uint256 ilRepayment = Math.min(gain, jtImpermanentLoss);
            jtImpermanentLoss -= ilRepayment;
            jtEffectiveNAV += ilRepayment;
            gain -= ilRepayment;
            lastCollateralNAV += ilRepayment;

            // STEP_ATTRIBUTE_RESIDUAL_GAIN: ST takes its floored pro-rata share, JT the residual
            // Seniority tie-break: a gain marked from a zero collateral checkpoint accrues to the senior tranche first
            uint256 stGain = lastCollateralNAV == 0 ? gain : Math.mulDiv(gain, stEffectiveNAV, lastCollateralNAV);
            uint256 jtGain = gain - stGain;

            // STEP_APPLY_JT_GAIN: the junior residual is pure fee-gated junior yield
            if (jtGain != 0) {
                if (jtGain > dust) jtProtocolFee = Math.mulDiv(jtGain, _e.jtProtocolFeeWAD, WAD);
                jtEffectiveNAV += jtGain;
            }

            // STEP_PAY_PREMIUMS: the senior residual is pure senior yield
            if (stGain != 0) {
                if (stGain > dust) premiumsPaid = true;
                (jtRiskPremium, lptLiquidityPremium) = _expectedPremiums(_e, stGain);
                if (jtRiskPremium != 0) {
                    if (premiumsPaid) jtProtocolFee += Math.mulDiv(jtRiskPremium, _e.jtYieldShareProtocolFeeWAD, WAD);
                    jtEffectiveNAV += jtRiskPremium;
                    stGain -= jtRiskPremium;
                }
                if (lptLiquidityPremium != 0) {
                    if (premiumsPaid) lptProtocolFee = Math.mulDiv(lptLiquidityPremium, _e.lptYieldShareProtocolFeeWAD, WAD);
                    stGain -= lptLiquidityPremium;
                }
                if (premiumsPaid) stProtocolFee = Math.mulDiv(stGain, _e.stProtocolFeeWAD, WAD);
                stEffectiveNAV += stGain + lptLiquidityPremium;
            }
        } else if (collateralNAVNew < lastCollateralNAV) {
            // STEP_APPLY_JT_LOSS + STEP_ST_INCURS_RESIDUAL_LOSSES: junior-first absorption, residual to ST
            uint256 loss = lastCollateralNAV - collateralNAVNew;
            uint256 jtImpermanentLossIncurred = Math.min(loss, jtEffectiveNAV);
            jtEffectiveNAV -= jtImpermanentLossIncurred;
            jtImpermanentLoss += jtImpermanentLossIncurred;
            loss -= jtImpermanentLossIncurred;
            if (loss != 0) stEffectiveNAV -= loss;
        }

        // The fee/premium theorem, checked rather than assumed: same-sign attribution means any nonzero fee or
        // premium requires a gain residual that fully recovered the IL, which resolves PERPETUAL instead
        if (_e.fixedTermActive) {
            assertEq(lptLiquidityPremium, 0, "theorem: a FIXED_TERM-resulting sync accrues no LPT premium");
            assertEq(stProtocolFee, 0, "theorem: a FIXED_TERM-resulting sync accrues no ST fee");
            assertEq(jtProtocolFee, 0, "theorem: a FIXED_TERM-resulting sync accrues no JT fee");
            assertEq(lptProtocolFee, 0, "theorem: a FIXED_TERM-resulting sync accrues no LPT fee");
        }

        _e.stEffectiveNAV = toNAVUnits(stEffectiveNAV);
        _e.jtEffectiveNAV = toNAVUnits(jtEffectiveNAV);
        _e.jtImpermanentLoss = toNAVUnits(jtImpermanentLoss);
        _e.lptLiquidityPremium = toNAVUnits(lptLiquidityPremium);
        _e.stProtocolFee = toNAVUnits(stProtocolFee);
        _e.jtProtocolFee = toNAVUnits(jtProtocolFee);
        _e.lptProtocolFee = toNAVUnits(lptProtocolFee);
        _e.jtRiskPremium = toNAVUnits(jtRiskPremium);
        _e.premiumsPaid = premiumsPaid;
        return _e;
    }

    /**
     * @notice The JT risk and LPT liquidity premiums for `_stGain`, from the full time-weighted accumulators
     *         at sync time averaged over the premium window.
     * @dev A same-block window (`premiumElapsed == 0`) uses the instantaneous shares over one second, exactly
     *      mirroring the accountant's `STEP_PAY_PREMIUMS` handling.
     */
    function _expectedPremiums(SyncExpectation memory _e, uint256 _stGain) internal pure returns (uint256 jtRiskPremium, uint256 lptLiquidityPremium) {
        uint256 twJT = _e.twJTStart + _e.jtYieldShareWAD * _e.elapsed;
        uint256 twLPT = _e.twLPTStart + _e.lptYieldShareWAD * _e.elapsed;
        uint256 premiumElapsed = _e.premiumElapsed;
        if (premiumElapsed == 0) {
            premiumElapsed = 1;
            twJT = _e.jtYieldShareWAD;
            twLPT = _e.lptYieldShareWAD;
        }
        jtRiskPremium = Math.mulDiv(_stGain, twJT, premiumElapsed * WAD);
        lptLiquidityPremium = Math.mulDiv(_stGain, twLPT, premiumElapsed * WAD);
    }

    /**
     * @notice Expected LPT premium and ST fee share mints, both floor-priced against the retained senior NAV
     *         `(stEffectiveNAVPost - prem - fee)` at the pre-sync supply.
     * @dev Mirrors `FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint`. The LPT protocol fee
     *      is carved out of the premium: the premium leg mints `(prem - lptFee)` and the fee leg mints `(fee + lptFee)`,
     *      so the LPT holds the premium net of the fee and the protocol receives the fee as senior shares. The retained
     *      denominator subtracts the gross premium and the ST fee, so the carve-out leaves it unchanged.
     */
    function _expectedPremiumShares(
        NAV_UNIT _prem,
        NAV_UNIT _fee,
        NAV_UNIT _lptFee,
        NAV_UNIT _stEffectiveNAVPost,
        uint256 _preSupply
    )
        internal
        pure
        returns (uint256 premShares, uint256 feeShares)
    {
        NAV_UNIT retainedSeniorNAV = toNAVUnits(toUint256(_stEffectiveNAVPost) - toUint256(_prem) - toUint256(_fee));
        premShares = _expectedShares(toNAVUnits(toUint256(_prem) - toUint256(_lptFee)), _preSupply, retainedSeniorNAV);
        feeShares = _expectedShares(toNAVUnits(toUint256(_fee) + toUint256(_lptFee)), _preSupply, retainedSeniorNAV);
    }

    /**
     * @notice Independent counterweight for the senior premium/fee/deposit share mints: every mint is floor-priced
     *         against the senior NAV retained by pre-existing holders, so their NAV-per-share can never fall across
     *         the operation. Cross-multiplied on plain checked integers, sharing nothing with the share-pricing mirror.
     * @dev `_mintedForValue` is the total NAV the mints paid for (premium + fee, plus the booked deposit value when
     *      a deposit rode the same sync). Pre-existing holders keep `preSupply / postSupply` of the post-op senior
     *      effective NAV, which must cover at least the value the checkpoint retains for them
     *      (`stEffectiveNAV - mintedForValue`): `stEffPost * preSupply >= (stEffPost - minted) * postSupply`.
     *
     *      Virtual-shares dust: every mint now prices against the effective supply (P + VIRTUAL_SHARES) over the
     *      effective denom (D + VIRTUAL_VALUE), so each mint M_i overshoots its fair floor by strictly less than
     *      v_i·VIRTUAL_SHARES/D_i (the OZ inflation-attack sliver). Summed and re-lumped against the shared
     *      `retained` denominator this gives `retained·totalMinted − mintedForValue·preSupply < mintedForValue·
     *      VIRTUAL_SHARES` (rigorous for the sync legs AND a deposit leg riding the same sync), so the bound below
     *      carries exactly that one-sided dust tolerance. It stays a real check: a genuine over-mint beyond the
     *      virtual-share sliver still trips it.
     */
    function _assertSeniorMintsNonDilutive(uint256 _stSupplyPre, NAV_UNIT _mintedForValue) internal view {
        uint256 stEffPost = toUint256(ACCOUNTANT.getState().lastSTEffectiveNAV);
        uint256 retained = stEffPost - toUint256(_mintedForValue);
        uint256 virtualShareDust = toUint256(_mintedForValue) * VIRTUAL_SHARES;
        assertGe(
            stEffPost * _stSupplyPre + virtualShareDust,
            retained * ST.totalSupply(),
            "the senior share mints must never dilute pre-existing holders beyond the virtual-shares offset dust"
        );
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
        IERC20(COLLATERAL_ASSET).approve(address(ST), _assets);
        r.shares = ST.deposit(toTrancheUnits(_assets), _lp);
        vm.stopPrank();
        r.post = _snap(_actorArray(_lp));
        _assertSolvency();
    }

    /// @notice Executes a JT deposit for `_lp` with an exact approval, snapshotting around it.
    function _doDepositJT(address _lp, uint256 _assets) internal returns (OpReceipt memory r) {
        r.pre = _snap(_actorArray(_lp));
        vm.startPrank(_lp);
        IERC20(COLLATERAL_ASSET).approve(address(JT), _assets);
        r.shares = JT.deposit(toTrancheUnits(_assets), _lp);
        vm.stopPrank();
        r.post = _snap(_actorArray(_lp));
        _assertSolvency();
    }

    /// @notice Executes a multi-asset LPT deposit for `_lp` with exact approvals, snapshotting around it.
    function _doDepositLPTMulti(address _lp, uint256 _collateralAssets, uint256 _quoteAssets, uint256 _minLPTAssetsOut) internal returns (OpReceipt memory r) {
        r.pre = _snap(_actorArray(_lp));
        vm.startPrank(_lp);
        IERC20(COLLATERAL_ASSET).approve(address(LPT), _collateralAssets);
        IERC20(testConfig.quoteAsset).approve(address(LPT), _quoteAssets);
        (r.shares,) = IRoycoLiquidityProviderTranche(address(LPT)).depositMultiAsset(_collateralAssets, _quoteAssets, _minLPTAssetsOut, _lp);
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

    /// @notice Executes an in-kind LPT redemption of `_shares` for `_lp`, snapshotting around it.
    function _doRedeemLPT(address _lp, uint256 _shares) internal returns (OpReceipt memory r) {
        r.pre = _snap(_actorArray(_lp));
        vm.prank(_lp);
        r.claims = LPT.redeem(_shares, _lp, _lp);
        r.post = _snap(_actorArray(_lp));
        _assertSolvency();
    }

    /// @notice Executes a multi-asset LPT redemption of `_shares` for `_lp`, snapshotting around it.
    function _doRedeemLPTMulti(address _lp, uint256 _shares, uint256 _minSTSharesOut, uint256 _minQuoteOut) internal returns (OpReceipt memory r) {
        r.pre = _snap(_actorArray(_lp));
        vm.prank(_lp);
        (r.claims, r.quoteAssets) = IRoycoLiquidityProviderTranche(address(LPT)).redeemMultiAsset(_shares, _minSTSharesOut, _minQuoteOut, _lp, _lp);
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
    /// @dev Both legs deposit the one collateral asset, sized per tranche.
    function _seedMarket(uint256 _stAssets, uint256 _jtAssets) internal {
        _depositJT(JT_ALICE_ADDRESS, _jtAssets);
        _depositST(ST_ALICE_ADDRESS, _stAssets);
    }

    /**
     * @notice First LPT entry via the multi-asset flow (the pool starts empty). Returns the LPT shares minted.
     * @dev The quote amount must be sized in the quote asset's own decimals.
     * @dev The entry ramps geometrically: the venue bootstrap leaves only a dust-deep pool and Balancer bounds
     *      each unbalanced add's invariant growth (about 5x), so every chunk is capped at roughly 3x the
     *      current depth. The near-peg quote valuation here only sizes the chunks, never an assertion.
     */
    function _seedLPT(address _lp, uint256 _collateralAssets, uint256 _quoteAssets) internal returns (uint256 shares) {
        _initializeLPTVenueIfNeeded();
        uint256 quoteUnitScale = 10 ** IERC20Metadata(testConfig.quoteAsset).decimals();
        uint256 collateralAssetsRemaining = _collateralAssets;
        uint256 quoteAssetsRemaining = _quoteAssets;
        for (uint256 i = 0; i < 64 && (collateralAssetsRemaining != 0 || quoteAssetsRemaining != 0); ++i) {
            // The invariant-ratio bound is against the WHOLE pool, so depth is the full BPT supply's value
            uint256 depthValue = toUint256(KERNEL.convertLPTAssetsToValue(toTrancheUnits(IERC20(POOL).totalSupply())));
            uint256 remainingValue = toUint256(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(collateralAssetsRemaining)))
                + Math.mulDiv(quoteAssetsRemaining, 1e18, quoteUnitScale);
            uint256 collateralAssetsChunk = collateralAssetsRemaining;
            uint256 quoteAssetsChunk = quoteAssetsRemaining;
            uint256 maxChunkValue = 3 * depthValue;
            if (remainingValue > maxChunkValue) {
                collateralAssetsChunk = Math.mulDiv(collateralAssetsRemaining, maxChunkValue, remainingValue);
                quoteAssetsChunk = Math.mulDiv(quoteAssetsRemaining, maxChunkValue, remainingValue);
            }
            shares += _doDepositLPTMulti(_lp, collateralAssetsChunk, quoteAssetsChunk, 0).shares;
            collateralAssetsRemaining -= collateralAssetsChunk;
            quoteAssetsRemaining -= quoteAssetsChunk;
        }
        if (collateralAssetsRemaining != 0 || quoteAssetsRemaining != 0) fail("_seedLPT: could not fully seed the LPT within the chunk budget");
    }

    /**
     * @dev One-time bootstrap of the LPT's market-making venue, invoked by `_seedLPT` before the first entry.
     *      Default no-op for venues that need none. The BalancerV3 family overrides this to initialize the
     *      freshly created pool through Balancer's canonical Router, because the repo ships no production
     *      initialization path for the pool (see the family override's note).
     */
    function _initializeLPTVenueIfNeeded() internal virtual { }

    /**
     * @notice Returns the collateral NAV the LAST sync committed (the measured post-simulate mark).
     * @dev A live pre-sync collateral NAV read can be stale against the transient price cache left populated
     *      by an earlier kernel op in the same test, while the sync itself re-caches the live rate. Measured
     *      deltas must therefore be read from the committed checkpoint right after the sync under test.
     */
    function _committedCollateralNAV() internal view returns (NAV_UNIT collateralNAV) {
        return ACCOUNTANT.getState().lastCollateralNAV;
    }

    /// @notice Enables the LPT overlay: `setMaxYieldShares(maxJT, maxLPT)` then `setMinLiquidity(minLiq)`.
    function _enableLPTOverlay(uint64 _maxJTShareWAD, uint64 _maxLPTShareWAD, uint64 _minLiquidityWAD) internal {
        _executeAccountantAdminOperationFresh(abi.encodeCall(ACCOUNTANT.setMaxYieldShares, (_maxJTShareWAD, _maxLPTShareWAD)));
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

    /// @notice Raises the market's dust tolerance via the delay-0 market ops role (held by the kernel admin wallet).
    function _raiseDustTolerance(NAV_UNIT _tol) internal {
        vm.prank(KERNEL_ADMIN_ADDRESS);
        ACCOUNTANT.setDustTolerance(_tol);
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
            uint256 coverageUtilizationWAD = _expectedCoverageUtilization(a.lastCollateralNAV, a.minCoverageWAD, a.lastJTEffectiveNAV);
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
        idleShares = KERNEL.getState().lptOwnedSeniorTrancheShares;
        assertGt(idleShares, 0, "arrange: no liquidity premium ST shares were staged");
    }

    // ── Preview + pause + blacklist utilities ──

    /**
     * @notice Simulates the non-view LPT multi-asset deposit preview through the venue's query mode.
     * @dev Executed as a regular call pranked to a zero tx.origin (Balancer V3's off-chain query context, the
     *      same pattern Balancer's own test base uses), wrapped in a state snapshot so no query-mode side
     *      effect can leak into the test. A revert is re-raised after the state rollback.
     */
    function _previewDepositLPTMulti(uint256 _stAssets, uint256 _quoteAssets) internal returns (uint256 shares) {
        uint256 snapshotId = vm.snapshotState();
        vm.prank(address(0), address(0));
        (bool ok, bytes memory ret) = address(LPT).call(abi.encodeCall(IRoycoLiquidityProviderTranche.previewDepositMultiAsset, (_stAssets, _quoteAssets)));
        vm.revertToState(snapshotId);
        if (!ok) _bubbleRevert(ret);
        (shares,) = abi.decode(ret, (uint256, uint256));
    }

    /**
     * @notice Simulates the non-view LPT multi-asset redemption preview through the venue's query mode.
     * @dev Executed as a regular call pranked to a zero tx.origin (Balancer V3's off-chain query context, the
     *      same pattern Balancer's own test base uses), wrapped in a state snapshot so no query-mode side
     *      effect can leak into the test. A revert is re-raised after the state rollback.
     */
    function _previewRedeemLPTMulti(uint256 _shares) internal returns (AssetClaims memory stClaims, uint256 quoteAssets) {
        uint256 snapshotId = vm.snapshotState();
        vm.prank(address(0), address(0));
        (bool ok, bytes memory ret) = address(LPT).call(abi.encodeCall(IRoycoLiquidityProviderTranche.previewRedeemMultiAsset, (_shares)));
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
        vm.prank(ORACLE_ADMIN_ADDRESS);
        bytes memory returnData;
        (ok, returnData) = address(KERNEL).call(abi.encodeWithSignature("setMaxReinvestmentSlippage(uint64)", _slippageWAD));
        if (!ok && returnData.length != 0) fail("the reinvestment slippage seam exists but its setter reverted");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    // ── Section-local helpers ──

    /**
     * @notice Measures the fresh post-simulate sync inputs (committed collateral NAV and the deposit valuation)
     *         under a reverted state snapshot, so a pending oracle move is read at the rate execution will actually use.
     * @dev A live pre-sync collateral NAV read is stale against the transient price cache left by an earlier kernel
     *      op in the same test transaction, so the mark is read from the checkpoint a throwaway sync commits and
     *      the whole probe is rolled back. The collateral NAV and pricing conversions are sync INPUTS, so this read is not circular with any assertion.
     */
    function _measureFreshSyncInputs(TRANCHE_UNIT _collateralAssets) internal returns (NAV_UNIT collateralNAV, NAV_UNIT depositValue) {
        uint256 snapshotId = vm.snapshotState();
        _sync();
        collateralNAV = _committedCollateralNAV();
        depositValue = KERNEL.convertCollateralAssetsToValue(_collateralAssets);
        vm.revertToState(snapshotId);
    }

    /**
     * @notice Simulates the kernel's preview-mode LPT multi-asset deposit flow.
     * @dev Pranked as the liquidity provider tranche (the flow's only permitted caller) with the preview flag set, so the
     *      previewed `lptAssetsOut` (the venue add's mint) is observable for event expectations. The flagged flow
     *      unwinds itself via its result-carrying revert, whose payload carries the previewed returns.
     */
    function _previewKernelDepositLPTMulti(
        uint256 _collateralAssets,
        uint256 _quoteAssets
    )
        internal
        returns (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, TRANCHE_UNIT lptAssetsOut, uint256 lptTotalSupplyAfterMints)
    {
        vm.prank(address(LPT), address(0));
        (bool ok, bytes memory ret) = address(KERNEL)
            .call(abi.encodeCall(IRoycoDayKernel.lptDepositMultiAsset, (true, toTrancheUnits(_collateralAssets), _quoteAssets, toTrancheUnits(0))));
        assertFalse(ok, "the flagged flow must unwind via its result-carrying revert");
        if (bytes4(ret) != DispatchLogic.SIMULATION_RESULT.selector) _bubbleRevert(ret);
        bytes memory simulationResult;
        assembly ("memory-safe") { simulationResult := add(ret, 0x44) }
        (depositNAV, effectiveNAV, lptAssetsOut) = abi.decode(simulationResult, (NAV_UNIT, NAV_UNIT, TRANCHE_UNIT));
        // The sync mints no LPT shares, so the live supply is the post-sync supply the share quote prices against
        lptTotalSupplyAfterMints = LPT.totalSupply();
    }

    /// @notice Sizes a quote-asset amount whose near-peg value approximates `_value` (one whole quote token per WAD of NAV).
    /// @dev Sizing only, mirroring `_seedLPT`'s near-peg valuation, never an assertion input.
    function _quoteAssetsForValue(NAV_UNIT _value) internal view returns (uint256 quoteAssets) {
        return Math.mulDiv(toUint256(_value), 10 ** IERC20Metadata(testConfig.quoteAsset).decimals(), WAD);
    }

    /// @notice Seeds the LPT with a value-matched two-leg entry: `_collateralLegAssets` of the collateral asset plus a near-peg quote leg of equal value.
    function _seedLPTBalanced(address _lp, uint256 _collateralLegAssets) internal returns (uint256 shares) {
        return _seedLPT(_lp, _collateralLegAssets, _quoteAssetsForValue(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(_collateralLegAssets))));
    }

    /// @notice Seeds the LPT with a market-scaled two-leg entry: a collateral leg of `initialFunding / 100` and a value-matched quote leg.
    function _seedDefaultLPT() internal {
        _setupLPTProviders();
        _seedLPTBalanced(LPT_ALICE_ADDRESS, testConfig.initialFunding / 100);
    }

    /**
     * @notice Derives the `minLiquidityWAD` that puts the committed liquidity utilization at `_targetUtilizationWAD`.
     * @dev Callers must have synced in the same block so the committed checkpoint is fresh. The narrowing cast
     *      is guarded, since a pool deeper than about twenty times the senior tranche would otherwise truncate
     *      the requirement silently into an arbitrary value.
     */
    function _minLiquidityForTargetUtilization(uint256 _targetUtilizationWAD) internal view returns (uint64 minLiquidityWAD) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 requirementWAD = Math.mulDiv(_targetUtilizationWAD, toUint256(a.lastLPTRawNAV), toUint256(a.lastSTEffectiveNAV));
        assertGt(requirementWAD, 0, "arrange: the computed minimum liquidity must be nonzero");
        assertLe(requirementWAD, uint256(type(uint64).max), "arrange: the computed minimum liquidity must fit uint64");
        minLiquidityWAD = uint64(requirementWAD);
    }

    /// @notice Arrange guard asserting that removing `_shares`' proportional BPT slice from the committed mark
    ///         would push the liquidity utilization above WAD.
    function _assertSliceWouldBreachLiquidity(uint256 _shares, uint64 _minLiquidityWAD, MarketSnapshot memory _pre) internal view {
        uint256 sliceValue = Math.mulDiv(toUint256(_pre.lastLPTRawNAV), _shares, LPT.totalSupply());
        assertGt(
            _expectedLiquidityUtilization(_pre.lastSTEffectiveNAV, _minLiquidityWAD, toNAVUnits(toUint256(_pre.lastLPTRawNAV) - sliceValue)),
            WAD,
            "arrange: the redemption must breach the liquidity requirement"
        );
    }

    /**
     * @notice Senior-deposit slack (in collateral tranche units) whose addition to `stMaxDeposit` guarantees a coverage breach.
     * @dev Derivation: `maxSTDeposit` under-reports the true breach boundary by exactly the single collateral
     *      dust tolerance, so a deposit must exceed it by more than `dustTolerance` in NAV to guarantee
     *      `coverageUtilizationWAD > WAD`. Each pricing conversion floors (up to one NAV-per-tranche-unit of error
     *      in each conversion involved), so the dust is converted to tranche units, doubled, and padded by six
     *      tranche-unit wei to strictly dominate the floor drift and the boundary itself.
     */
    function _stMaxDepositBreachSlackAssets() internal view returns (uint256 slackAssets) {
        slackAssets = 2 * toUint256(KERNEL.convertValueToCollateralAssets(ACCOUNTANT.getState().dustTolerance)) + 6;
    }

    /// @notice Asserts that a fresh snapshot matches `_pre` on every supply, ledger, checkpoint, and balance field (atomicity check).
    function _assertMarketUnchanged(MarketSnapshot memory _pre) internal view {
        MarketSnapshot memory post = _snap();
        assertEq(post.stSupply, _pre.stSupply, "atomicity: ST supply moved");
        assertEq(post.jtSupply, _pre.jtSupply, "atomicity: JT supply moved");
        assertEq(post.lptSupply, _pre.lptSupply, "atomicity: LPT supply moved");
        assertEq(post.collateralOwned, _pre.collateralOwned, "atomicity: collateralOwned moved");
        assertEq(post.lptOwned, _pre.lptOwned, "atomicity: lptOwned moved");
        assertEq(post.lptOwnedSeniorTrancheShares, _pre.lptOwnedSeniorTrancheShares, "atomicity: idle liquidity premium shares moved");
        assertEq(post.lastCollateralNAV, _pre.lastCollateralNAV, "atomicity: committed collateral NAV moved");
        assertEq(post.lastLPTRawNAV, _pre.lastLPTRawNAV, "atomicity: committed LPT raw NAV moved");
        assertEq(post.lastSTEffectiveNAV, _pre.lastSTEffectiveNAV, "atomicity: committed ST effective NAV moved");
        assertEq(post.lastJTEffectiveNAV, _pre.lastJTEffectiveNAV, "atomicity: committed JT effective NAV moved");
        assertEq(post.lastJTImpermanentLoss, _pre.lastJTImpermanentLoss, "atomicity: committed JT IL moved");
        assertTrue(post.marketState == _pre.marketState, "atomicity: market state moved");
        assertEq(post.kernelCollateralBal, _pre.kernelCollateralBal, "atomicity: kernel collateral balance moved");
        assertEq(post.kernelBPTBal, _pre.kernelBPTBal, "atomicity: kernel BPT balance moved");
        assertEq(post.kernelSTShareBal, _pre.kernelSTShareBal, "atomicity: kernel ST share balance moved");
        assertEq(post.feeRecipientSTShares, _pre.feeRecipientSTShares, "atomicity: fee recipient ST shares moved");
        assertEq(post.feeRecipientJTShares, _pre.feeRecipientJTShares, "atomicity: fee recipient JT shares moved");
        assertEq(post.feeRecipientLPTShares, _pre.feeRecipientLPTShares, "atomicity: fee recipient LPT shares moved");
    }

    // ── ST/JT first deposits ──

    /**
     * @notice A first JT deposit mints shares 1:1 with the deposited value and commits `collateralNAV == jtEffectiveNAV` exactly.
     * @dev The deposited value is captured through the pricing path before the first kernel op of the test, so it is the
     *      same live rate the deposit's own price cache resolves.
     */
    function test_JTDeposit_firstDeposit_mintsSharesOneToOne() public {
        uint256 assets = testConfig.initialFunding / 10;
        NAV_UNIT value = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(assets));
        assertGt(toUint256(value), 0, "arrange: the deposit value must be nonzero");
        MarketSnapshot memory pre = _snap();

        vm.startPrank(JT_ALICE_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(JT), assets);
        _expectDeposit(address(JT), JT_ALICE_ADDRESS, JT_ALICE_ADDRESS, toTrancheUnits(assets), toUint256(value));
        uint256 shares = JT.deposit(toTrancheUnits(assets), JT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        MarketSnapshot memory post = _snap();
        assertEq(shares, toUint256(value), "first JT mint must be 1:1 with the deposited value");
        assertEq(JT.balanceOf(JT_ALICE_ADDRESS), shares, "receiver JT share balance");
        assertEq(post.collateralOwned, pre.collateralOwned + toTrancheUnits(assets), "collateralOwned must grow by the deposited assets");
        assertEq(post.jtSupply, pre.jtSupply + shares, "JT supply must grow by exactly the minted shares");
        // The pre-deposit ledger is empty, so the single-conversion mark is exactly the standalone deposit value
        assertEq(post.lastCollateralNAV, value, "committed collateral NAV must equal the deposited value");
        assertEq(post.lastJTEffectiveNAV, post.lastCollateralNAV, "committed JT effective NAV must equal the collateral NAV");
        assertEq(post.lastSTEffectiveNAV, ZERO_NAV_UNITS, "committed ST effective NAV must stay zero");
        // With collateralNAV == jtEffectiveNAV the coverage utilization is exactly minCoverage
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
        NAV_UNIT value = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(assets));
        MarketSnapshot memory pre = _snap();
        // The merged-conversion mark can add at most 1 wei over pre + value, immaterial against the half-max headroom
        assertLe(
            _expectedCoverageUtilization(pre.lastCollateralNAV + value, ACCOUNTANT.getState().minCoverageWAD, pre.lastJTEffectiveNAV),
            WAD,
            "arrange: the deposit must satisfy coverage"
        );

        vm.startPrank(ST_ALICE_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(ST), assets);
        _expectDeposit(address(ST), ST_ALICE_ADDRESS, ST_ALICE_ADDRESS, toTrancheUnits(assets), toUint256(value));
        uint256 shares = ST.deposit(toTrancheUnits(assets), ST_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        MarketSnapshot memory post = _snap();
        assertEq(shares, toUint256(value), "first ST mint must be 1:1 with the deposited value");
        assertEq(ST.balanceOf(ST_ALICE_ADDRESS), shares, "receiver ST share balance");
        assertEq(post.collateralOwned, pre.collateralOwned + toTrancheUnits(assets), "collateralOwned must grow by the deposited assets");
        assertEq(post.stSupply, pre.stSupply + shares, "ST supply must grow by exactly the minted shares");
        // Single-conversion mark: the booked delta is convert(pre + assets) - convert(pre), which can exceed
        // the standalone convert(assets) by at most 1 wei (floor superadditivity), never undershoot it
        NAV_UNIT bookedDelta = post.lastCollateralNAV - pre.lastCollateralNAV;
        assertGe(bookedDelta, value, "the booked collateral delta must cover the standalone deposit value");
        assertLe(bookedDelta, value + toNAVUnits(uint256(1)), "the merged conversion can add at most 1 wei over the standalone value");
        assertEq(post.lastSTEffectiveNAV, bookedDelta, "committed ST effective NAV must book the whole deposit delta");
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV, "the junior effective NAV must be untouched");
        // The production value is read via a same-block flat sync (a no-op on the committed state), never recomputed by the suite
        assertEq(
            _syncWithState().coverageUtilizationWAD,
            _expectedCoverageUtilization(post.lastCollateralNAV, ACCOUNTANT.getState().minCoverageWAD, pre.lastJTEffectiveNAV),
            "production coverage utilization must match the independent recompute"
        );
        _assertCommittedConservation();
    }

    // ── ST deposit pricing, previews, and gates ──

    /// @notice After committed yield an ST deposit mints exactly `floor(value * supply / stEffectiveNAV)` shares and the
    ///         post-op checkpoint books exactly the measured collateral delta into the senior effective NAV.
    function test_STDeposit_exactSharePricing_afterYield() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applySTYield(0.05e18);
        _sync();

        uint256 assets = testConfig.initialFunding / 10;
        NAV_UNIT value = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(assets));
        uint256 stSupply = ST.totalSupply();
        NAV_UNIT stEffectiveNAV = ACCOUNTANT.getState().lastSTEffectiveNAV;
        uint256 expectedShares = _expectedShares(value, stSupply, stEffectiveNAV);
        MarketSnapshot memory pre = _snap();

        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(ST), assets);
        _expectDeposit(address(ST), ST_BOB_ADDRESS, ST_BOB_ADDRESS, toTrancheUnits(assets), expectedShares);
        uint256 shares = ST.deposit(toTrancheUnits(assets), ST_BOB_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        MarketSnapshot memory post = _snap();
        assertEq(shares, expectedShares, "deposit shares must match the independent floor pricing exactly");
        NAV_UNIT measuredDelta = post.lastCollateralNAV - pre.lastCollateralNAV;
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV + measuredDelta, "post ST effective NAV must grow by exactly the measured collateral delta");
        assertApproxEqAbs(measuredDelta, value, maxNAVDelta(), "the collateral delta must round-trip the deposited value through the pricing path");
        assertEq(post.stSupply, pre.stSupply + shares, "no fee mint may accompany a same-block deposit");
        assertEq(post.collateralOwned, pre.collateralOwned + toTrancheUnits(assets), "collateralOwned must grow by the deposited assets");
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
        // The pricing-path value of the deposited assets, the collateral delta the deposit must book
        NAV_UNIT depositNAV = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(assets));
        uint256 previewShares = ST.previewDeposit(toTrancheUnits(assets));
        OpReceipt memory r = _doDepositST(ST_BOB_ADDRESS, assets);

        assertEq(r.shares, previewShares, "previewDeposit must equal the executed deposit exactly");
        assertApproxEqAbs(
            r.post.lastCollateralNAV - r.pre.lastCollateralNAV, depositNAV, maxNAVDelta(), "the priced deposit must match the booked collateral delta"
        );
        assertEq(r.post.stSupply, r.pre.stSupply + r.shares, "supply must grow by exactly the minted shares");
        _assertCommittedConservation();
    }

    /// @notice A zero-asset ST deposit reverts with the accountant's exact-arg `INVALID_POST_OP_STATE(ST_DEPOSIT)`.
    /// @dev The post-op sync's `deltaCollateralNAV > 0` requirement fires before the tranche's `INVALID_DEPOSIT_NAV` check can.
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
        IERC20(COLLATERAL_ASSET).approve(address(ST), assets);
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
        IERC20(COLLATERAL_ASSET).approve(address(ST), assets);
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
        IERC20(COLLATERAL_ASSET).approve(address(ST), breachAssets);
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
    function test_RevertIf_STDepositBreachesLiquidity() public whenLPT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _seedDefaultLPT();
        _setMinLiquidityWAD(0.1e18);
        _sync();
        MarketSnapshot memory pre = _snap();
        assertLe(pre.liquidityUtilizationWAD, WAD, "arrange: liquidity must start satisfied");

        uint256 assets = (testConfig.initialFunding / 10) * 3;
        NAV_UNIT value = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(assets));
        assertGt(
            _expectedLiquidityUtilization(pre.lastSTEffectiveNAV + value, 0.1e18, pre.lastLPTRawNAV),
            WAD,
            "arrange: the deposit must breach the liquidity requirement"
        );
        assertLe(
            _expectedCoverageUtilization(pre.lastCollateralNAV + value, ACCOUNTANT.getState().minCoverageWAD, pre.lastJTEffectiveNAV),
            WAD,
            "arrange: coverage must not be the binding gate"
        );

        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(ST), assets);
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
        IERC20(COLLATERAL_ASSET).approve(address(ST), breachAssets);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        ST.deposit(toTrancheUnits(breachAssets), ST_BOB_ADDRESS);
        vm.stopPrank();
    }

    /**
     * @notice With a nonzero minimum liquidity whose headroom undercuts the coverage headroom, `stMaxDeposit`
     *         reports the independent liquidity-leg recompute: the max-size deposit lands under the gate and the same
     *         deposit plus the documented slack reverts with `LIQUIDITY_REQUIREMENT_VIOLATED`.
     * @dev The liquidity leg mirrors `RoycoDayAccountant.maxSTDeposit`: `floor(lptRawNAV * WAD / minLiquidity) -
     *      stEffectiveNAV - dustTolerance`. The coverage-derived breach slack strictly dominates the liquidity
     *      boundary's under-report (the single dust tolerance plus conversion floors), so it is reused.
     */
    function test_STDeposit_maxDepositExactlyDepositable_liquidityBound() public whenLPT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _seedDefaultLPT();
        _setMinLiquidityWAD(_minLiquidityForTargetUtilization(0.5e18));
        _sync();

        // Independent two-leg recompute with the liquidity leg binding
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 liquidityHeadroomValue =
            Math.mulDiv(toUint256(a.lastLPTRawNAV), WAD, a.minLiquidityWAD) - toUint256(a.lastSTEffectiveNAV) - toUint256(a.dustTolerance);
        uint256 coverageHeadroomValue =
            Math.mulDiv(toUint256(a.lastJTEffectiveNAV), WAD, a.minCoverageWAD) - (toUint256(a.lastCollateralNAV) + toUint256(a.dustTolerance));
        assertLt(liquidityHeadroomValue, coverageHeadroomValue, "arrange: liquidity must be the binding leg");
        TRANCHE_UNIT maxAssets = ST.maxDeposit(ST_BOB_ADDRESS);
        assertEq(
            maxAssets,
            KERNEL.convertValueToCollateralAssets(toNAVUnits(liquidityHeadroomValue)),
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
        IERC20(COLLATERAL_ASSET).approve(address(ST), breachAssets);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        ST.deposit(toTrancheUnits(breachAssets), ST_BOB_ADDRESS);
        vm.stopPrank();
    }

    /**
     * @notice A deposit following unsynced yield emits exact-args `ProtocolFeeSharesMinted` (on ST and JT) and
     *         `Deposit` events, with every value derived from the independent tranche accounting recomputation.
     * @dev The measured post-simulate collateral NAV and the deposit valuation are read via `_measureFreshSyncInputs`
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
        assertGt(e.collateralNAVNew, e.lastCollateralNAV, "arrange: the collateral NAV must have appreciated");
        uint256 assets = testConfig.initialFunding / 10;
        (, NAV_UNIT value) = _measureFreshSyncInputs(toTrancheUnits(assets));
        assertTrue(e.premiumsPaid, "arrange: the yield must clear the dust gate");
        assertGt(toUint256(e.stProtocolFee), 0, "arrange: an ST protocol fee must accrue");
        assertGt(toUint256(e.jtProtocolFee), 0, "arrange: a JT yield-share protocol fee must accrue");

        (uint256 premShares, uint256 stFeeShares) =
            _expectedPremiumShares(e.lptLiquidityPremium, e.stProtocolFee, e.lptProtocolFee, e.stEffectiveNAV, stSupplyPre);
        uint256 jtFeeShares = _expectedShares(e.jtProtocolFee, jtSupplyPre, e.jtEffectiveNAV - e.jtProtocolFee);
        uint256 expectedDepositShares = _expectedShares(value, stSupplyPre + premShares + stFeeShares, e.stEffectiveNAV);
        uint256 feeRecipientSTPre = ST.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);
        uint256 feeRecipientJTPre = JT.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);

        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(ST), assets);
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
        assertEq(aPost.lastJTEffectiveNAV, e.jtEffectiveNAV, "committed JT effective NAV must match the independent recomputation");
        // The deposit's booked delta is the committed collateral NAV over the pre-op sync's measured mark
        assertEq(
            aPost.lastSTEffectiveNAV,
            e.stEffectiveNAV + (aPost.lastCollateralNAV - e.collateralNAVNew),
            "committed ST effective NAV must be the sync output plus the deposit"
        );
        assertEq(aPost.lastJTImpermanentLoss, e.jtImpermanentLoss, "committed IL must match the independent recomputation");
        assertEq(uint256(aPost.lastPremiumPaymentTimestamp), block.timestamp, "the premium payment must stamp");
        assertEq(uint256(aPost.twJTYieldShareAccruedWAD), 0, "the accrual accumulators must reset after payment");
        // Counterweight independent of the share-pricing mirror: the premium, fee, and deposit mints all pay for
        // real value, so the pre-existing holders' NAV-per-share cannot fall across the whole operation.
        _assertSeniorMintsNonDilutive(stSupplyPre, e.lptLiquidityPremium + e.stProtocolFee + (aPost.lastCollateralNAV - e.collateralNAVNew));
        _assertCommittedConservation();
    }

    // ── JT deposit pricing, previews, and gates ──

    /// @notice After committed yield a JT deposit mints exactly `floor(value * supply / jtEffectiveNAV)` shares, books exactly
    ///         the measured collateral delta into the junior effective NAV, and lowers coverage utilization to the independent recompute.
    function test_JTDeposit_exactSharePricing_afterYield() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applyJTYield(0.05e18);
        _sync();

        uint256 assets = testConfig.initialFunding / 10;
        NAV_UNIT value = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(assets));
        uint256 jtSupply = JT.totalSupply();
        NAV_UNIT jtEffectiveNAV = ACCOUNTANT.getState().lastJTEffectiveNAV;
        uint256 expectedShares = _expectedShares(value, jtSupply, jtEffectiveNAV);

        MarketSnapshot memory pre = _snap();
        vm.startPrank(JT_BOB_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(JT), assets);
        _expectDeposit(address(JT), JT_BOB_ADDRESS, JT_BOB_ADDRESS, toTrancheUnits(assets), expectedShares);
        uint256 shares = JT.deposit(toTrancheUnits(assets), JT_BOB_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        MarketSnapshot memory post = _snap();
        assertEq(shares, expectedShares, "deposit shares must match the independent floor pricing exactly");
        NAV_UNIT measuredDelta = post.lastCollateralNAV - pre.lastCollateralNAV;
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV + measuredDelta, "post JT effective NAV must grow by exactly the measured collateral delta");
        assertApproxEqAbs(measuredDelta, value, maxNAVDelta(), "the collateral delta must round-trip the deposited value through the pricing path");
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV, "the senior effective NAV must be untouched");
        assertEq(post.jtSupply, pre.jtSupply + shares, "no fee mint may accompany a same-block deposit");
        assertEq(post.collateralOwned, pre.collateralOwned + toTrancheUnits(assets), "collateralOwned must grow by the deposited assets");
        uint256 expectedCovUtilWAD =
            _expectedCoverageUtilization(pre.lastCollateralNAV + measuredDelta, ACCOUNTANT.getState().minCoverageWAD, pre.lastJTEffectiveNAV + measuredDelta);
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
        // The pricing-path value of the deposited assets, the collateral delta the deposit must book
        NAV_UNIT depositNAV = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(assets));
        uint256 previewShares = JT.previewDeposit(toTrancheUnits(assets));
        OpReceipt memory r = _doDepositJT(JT_BOB_ADDRESS, assets);

        assertEq(r.shares, previewShares, "previewDeposit must equal the executed deposit exactly");
        assertApproxEqAbs(
            r.post.lastCollateralNAV - r.pre.lastCollateralNAV, depositNAV, maxNAVDelta(), "the priced deposit must match the booked collateral delta"
        );
        assertEq(r.post.jtSupply, r.pre.jtSupply + r.shares, "supply must grow by exactly the minted shares");
        _assertCommittedConservation();
    }

    /// @notice A zero-asset JT deposit reverts with the accountant's exact-arg `INVALID_POST_OP_STATE(JT_DEPOSIT)`.
    /// @dev The post-op sync's `deltaCollateralNAV > 0` requirement fires before the tranche's `INVALID_DEPOSIT_NAV` check can.
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
        IERC20(COLLATERAL_ASSET).approve(address(JT), assets);
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
        // Brink floor derivation: stMaxDeposit under-reports the exact coverage boundary only by the single dust
        // tolerance plus pricing conversion floors, wei-to-dust magnitudes against a collateral NAV seeded from
        // `initialFunding`, so the max-size deposit parks utilization within a sliver of 100%. A 99% floor is
        // orders of magnitude above that slack and cleanly separates "at the brink" from a failed arrange.
        assertGt(rST.post.coverageUtilizationWAD, (WAD * 99) / 100, "arrange: coverage utilization must sit at the brink");

        assertEq(JT.maxDeposit(JT_BOB_ADDRESS), MAX_TRANCHE_UNITS, "jtMaxDeposit must report the unbounded sentinel");
        OpReceipt memory rJT = _doDepositJT(JT_BOB_ADDRESS, testConfig.initialFunding / 10);
        assertGt(rJT.shares, 0, "the coverage-improving JT deposit must succeed");
        assertLt(rJT.post.coverageUtilizationWAD, rST.post.coverageUtilizationWAD, "the JT deposit must lower coverage utilization");
        _assertCommittedConservation();
    }

    // ── LPT deposits ──

    /**
     * @notice The first LPT multi-asset deposit mints LPT shares 1:1 with the minted BPT value, mints the senior leg
     *         at the committed senior rate, and emits an exact-args `MultiAssetDeposit`.
     * @dev The freshly initialized venue holds only dust depth and Balancer bounds each unbalanced add's invariant
     *      growth, so the first entry is capped at the live venue depth (each leg at most the whole pool's value)
     *      rather than a funding-derived constant. `minLPTAssetsOut` is set to the previewed venue mint, doubling as
     *      a min-out-passes-at-equality check.
     */
    function test_LPTDepositMultiAsset_firstDeposit_exactPricing() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _setupLPTProviders();
        _initializeLPTVenueIfNeeded();
        _sync();

        uint256 depthCapAssets = toUint256(KERNEL.convertValueToCollateralAssets(KERNEL.convertLPTAssetsToValue(toTrancheUnits(IERC20(POOL).totalSupply()))));
        assertGt(depthCapAssets, 0, "arrange: the initialized venue must carry nonzero depth");
        uint256 collateralAssets = Math.min(testConfig.initialFunding / 1_000_000, depthCapAssets);
        NAV_UNIT collateralValue = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(collateralAssets));
        uint256 quoteAssets = _quoteAssetsForValue(collateralValue);
        assertGt(quoteAssets, 0, "arrange: the quote leg must be nonzero");
        uint256 expectedSTSharesMinted = _expectedShares(collateralValue, ST.totalSupply(), ACCOUNTANT.getState().lastSTEffectiveNAV);
        (NAV_UNIT previewValue,, TRANCHE_UNIT previewLptAssetsOut, uint256 previewLptSupply) = _previewKernelDepositLPTMulti(collateralAssets, quoteAssets);
        assertEq(previewLptSupply, 0, "arrange: the first LPT mint must price against zero supply");
        uint256 expectedShares = toUint256(previewValue);
        MarketSnapshot memory pre = _snap();
        uint256 quoteBalPre = IERC20(testConfig.quoteAsset).balanceOf(LPT_ALICE_ADDRESS);

        vm.startPrank(LPT_ALICE_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(LPT), collateralAssets);
        IERC20(testConfig.quoteAsset).approve(address(LPT), quoteAssets);
        vm.expectEmit(true, true, false, true, address(LPT));
        emit IRoycoLiquidityProviderTranche.MultiAssetDeposit(
            LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS, collateralAssets, quoteAssets, toUint256(previewLptAssetsOut), expectedShares
        );
        (uint256 shares,) =
            IRoycoLiquidityProviderTranche(address(LPT)).depositMultiAsset(collateralAssets, quoteAssets, toUint256(previewLptAssetsOut), LPT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        MarketSnapshot memory post = _snap();
        // The independent first-mint pin: shares equal the EXECUTED venue mint valued through the pricing path (an
        // input), so a shared preview/execution valuation bug cannot hide. The preview equality below is parity only
        assertEq(shares, toUint256(KERNEL.convertLPTAssetsToValue(post.lptOwned - pre.lptOwned)), "the first LPT mint must be 1:1 with the minted BPT value");
        assertEq(shares, expectedShares, "the previewed depositNAV must equal the executed mint (parity)");
        assertEq(LPT.balanceOf(LPT_ALICE_ADDRESS), shares, "receiver LPT share balance");
        assertEq(post.lptOwned, pre.lptOwned + previewLptAssetsOut, "lptOwned must grow by exactly the previewed venue mint");
        assertEq(post.collateralOwned, pre.collateralOwned + toTrancheUnits(collateralAssets), "collateralOwned must grow by the senior leg");
        assertEq(post.stSupply, pre.stSupply + expectedSTSharesMinted, "the senior leg must mint at the committed senior rate");
        assertEq(post.lptSupply, pre.lptSupply + shares, "LPT supply must grow by exactly the minted shares");
        assertEq(post.lptOwnedSeniorTrancheShares, pre.lptOwnedSeniorTrancheShares, "no idle liquidity premium may be staged by a deposit");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal, "the minted senior shares must all land in the venue");
        assertEq(quoteBalPre - IERC20(testConfig.quoteAsset).balanceOf(LPT_ALICE_ADDRESS), quoteAssets, "the quote leg must be pulled exactly");
        assertEq(post.lastLPTRawNAV, KERNEL.convertLPTAssetsToValue(post.lptOwned), "committed LPT raw NAV must be the fresh venue mark");
        assertLe(post.liquidityUtilizationWAD, pre.liquidityUtilizationWAD, "an LPT deposit can only improve liquidity utilization");
        _assertCommittedConservation();
    }

    /// @notice The LPT multi-asset deposit preview equals execution exactly, both for the minted shares and the
    ///         venue's LPT assets out.
    function test_LPTDepositMultiAsset_previewParity() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
        _sync();

        uint256 collateralAssets = testConfig.initialFunding / 500;
        uint256 quoteAssets = _quoteAssetsForValue(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(collateralAssets)));
        uint256 previewShares = _previewDepositLPTMulti(collateralAssets, quoteAssets);
        (,, TRANCHE_UNIT previewLptAssetsOut,) = _previewKernelDepositLPTMulti(collateralAssets, quoteAssets);

        OpReceipt memory r = _doDepositLPTMulti(LPT_BOB_ADDRESS, collateralAssets, quoteAssets, 0);
        assertEq(r.shares, previewShares, "the previewed shares must equal execution exactly");
        assertEq(r.post.lptOwned, r.pre.lptOwned + previewLptAssetsOut, "the previewed LPT assets out must equal the executed venue mint");
        assertEq(r.post.lptSupply, r.pre.lptSupply + r.shares, "LPT supply must grow by exactly the minted shares");
        _assertCommittedConservation();
    }

    /// @notice A multi-asset LPT deposit with zero of both constituent legs reverts with `MUST_DEPOSIT_NON_ZERO_ASSETS`.
    /// @dev The selector is declared identically on `IRoycoDayKernel` and `IRoycoLiquidityProviderTranche`, the kernel's declaration reverts.
    function test_RevertIf_LPTDepositMultiAssetBothLegsZero() public whenLPT {
        _setupLPTProviders();
        vm.prank(LPT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayKernel.MUST_DEPOSIT_NON_ZERO_ASSETS.selector);
        IRoycoLiquidityProviderTranche(address(LPT)).depositMultiAsset(0, 0, 0, LPT_ALICE_ADDRESS);
    }

    /**
     * @notice A multi-asset LPT deposit whose `minLPTAssetsOut` exceeds the venue mint reverts inside Balancer with
     *         `BptAmountOutBelowMin` and leaves the whole market state untouched (atomicity).
     * @dev No deadline parameter exists anywhere on this surface, only the min-out bound asserted here.
     */
    function test_RevertIf_LPTDepositMultiAssetMinLPTAssetsOutBreached_atomic() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
        _sync();

        uint256 collateralAssets = testConfig.initialFunding / 500;
        uint256 quoteAssets = _quoteAssetsForValue(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(collateralAssets)));
        (,, TRANCHE_UNIT previewLptAssetsOut,) = _previewKernelDepositLPTMulti(collateralAssets, quoteAssets);
        uint256 breachingMinOut = toUint256(previewLptAssetsOut) + 1;
        MarketSnapshot memory pre = _snap();

        vm.startPrank(LPT_ALICE_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(LPT), collateralAssets);
        IERC20(testConfig.quoteAsset).approve(address(LPT), quoteAssets);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.BptAmountOutBelowMin.selector, toUint256(previewLptAssetsOut), breachingMinOut));
        IRoycoLiquidityProviderTranche(address(LPT)).depositMultiAsset(collateralAssets, quoteAssets, breachingMinOut, LPT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertMarketUnchanged(pre);
    }

    /// @notice In a fixed-term market a quote-only multi-asset LPT deposit succeeds (minting no senior shares) while
    ///         any ST-leg deposit reverts, and the preview bubbles the same revert for the disabled shape.
    function test_LPTDepositMultiAsset_quoteOnly_allowedInFixedTerm_stLegReverts() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
        _enterFixedTerm();

        uint256 quoteAssets = _quoteAssetsForValue(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(testConfig.initialFunding / 1000)));
        uint256 lptSupplyPre = LPT.totalSupply();
        MarketSnapshot memory pre = _snap();
        assertEq(pre.lptOwnedSeniorTrancheShares, 0, "arrange: no staged premium may exist");
        uint256 previewShares = _previewDepositLPTMulti(0, quoteAssets);

        OpReceipt memory r = _doDepositLPTMulti(LPT_BOB_ADDRESS, 0, quoteAssets, 0);
        assertEq(r.shares, previewShares, "the quote-only preview must equal execution");
        NAV_UNIT depositNAV = KERNEL.convertLPTAssetsToValue(r.post.lptOwned - r.pre.lptOwned);
        assertEq(r.shares, _expectedShares(depositNAV, lptSupplyPre, pre.lastLPTRawNAV), "quote-only shares must price at the pre-deposit LPT effective NAV");
        assertEq(r.post.stSupply, r.pre.stSupply, "a quote-only deposit must mint no senior shares");
        assertEq(r.post.collateralOwned, r.pre.collateralOwned, "a quote-only deposit must add no collateral assets");
        assertTrue(r.post.marketState == MarketState.FIXED_TERM, "the market must remain in the fixed term");

        uint256 collateralAssets = testConfig.initialFunding / 1000;
        vm.startPrank(LPT_BOB_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(LPT), collateralAssets);
        IERC20(testConfig.quoteAsset).approve(address(LPT), quoteAssets);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        IRoycoLiquidityProviderTranche(address(LPT)).depositMultiAsset(collateralAssets, quoteAssets, 0, LPT_BOB_ADDRESS);
        vm.stopPrank();

        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        IRoycoLiquidityProviderTranche(address(LPT)).previewDepositMultiAsset(collateralAssets, quoteAssets);
        _assertCommittedConservation();
    }

    /**
     * @notice An in-kind LPT deposit of BPT mints exactly `floor(value * supply / lptEffectiveNAV)` shares against the
     *         committed LPT mark, with an exact-args `Deposit` event.
     * @dev The BPT is obtained through the only user path to holding it, a prior in-kind redemption.
     */
    function test_LPTDeposit_inKind_exactSharePricing() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
        OpReceipt memory rRedeem = _doRedeemLPT(LPT_ALICE_ADDRESS, LPT.balanceOf(LPT_ALICE_ADDRESS) / 4);
        uint256 bptAssets = toUint256(rRedeem.claims.lptAssets);
        assertGt(bptAssets, 0, "arrange: the redemption must pay out BPT");
        assertEq(IERC20(POOL).balanceOf(LPT_ALICE_ADDRESS), bptAssets, "arrange: the redeemer must hold the BPT");
        _sync();

        NAV_UNIT value = KERNEL.convertLPTAssetsToValue(toTrancheUnits(bptAssets));
        uint256 lptSupply = LPT.totalSupply();
        MarketSnapshot memory pre = _snap();
        assertEq(pre.lptOwnedSeniorTrancheShares, 0, "arrange: no staged premium may exist");
        uint256 expectedShares = _expectedShares(value, lptSupply, pre.lastLPTRawNAV);

        vm.startPrank(LPT_ALICE_ADDRESS);
        IERC20(POOL).approve(address(LPT), bptAssets);
        _expectDeposit(address(LPT), LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS, toTrancheUnits(bptAssets), expectedShares);
        uint256 shares = LPT.deposit(toTrancheUnits(bptAssets), LPT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        MarketSnapshot memory post = _snap();
        assertEq(shares, expectedShares, "in-kind LPT shares must match the independent floor pricing exactly");
        assertEq(post.lptOwned, pre.lptOwned + toTrancheUnits(bptAssets), "lptOwned must grow by the deposited BPT");
        assertEq(post.lptSupply, pre.lptSupply + shares, "LPT supply must grow by exactly the minted shares");
        assertApproxEqAbs(post.lastLPTRawNAV - pre.lastLPTRawNAV, value, maxNAVDelta(), "the committed LPT mark must grow by the deposited value");
        _assertCommittedConservation();
    }

    /// @notice LPT deposits are never gated: the in-kind and quote-only flows succeed with the liquidity requirement
    ///         breached and in a fixed term, `lptMaxDeposit` stays unbounded, and only a pause zeroes it.
    function test_LPTDeposit_neverGated_evenInFixedTermOrLiquidityBreach() public whenLPT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _seedDefaultLPT();
        // Obtain BPT while the liquidity gate is still open (baseline minLiquidity is zero)
        OpReceipt memory rRedeem = _doRedeemLPT(LPT_ALICE_ADDRESS, LPT.balanceOf(LPT_ALICE_ADDRESS) / 2);
        uint256 bptAssets = toUint256(rRedeem.claims.lptAssets);
        assertGt(bptAssets, 0, "arrange: the redemption must pay out BPT");

        // Arrange A: breach the liquidity requirement outright
        _setMinLiquidityWAD(0.9e18);
        _sync();
        assertGt(_snap().liquidityUtilizationWAD, WAD, "arrange: the liquidity requirement must be breached");
        assertEq(LPT.maxDeposit(LPT_ALICE_ADDRESS), MAX_TRANCHE_UNITS, "lptMaxDeposit must stay unbounded while breached");
        vm.startPrank(LPT_ALICE_ADDRESS);
        IERC20(POOL).approve(address(LPT), bptAssets / 2);
        uint256 inKindShares = LPT.deposit(toTrancheUnits(bptAssets / 2), LPT_ALICE_ADDRESS);
        vm.stopPrank();
        assertGt(inKindShares, 0, "the in-kind deposit must succeed while breached");
        uint256 quoteAssets = _quoteAssetsForValue(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(testConfig.initialFunding / 1000)));
        assertGt(_doDepositLPTMulti(LPT_ALICE_ADDRESS, 0, quoteAssets, 0).shares, 0, "the quote-only deposit must succeed while breached");

        // Arrange B: fixed term
        _enterFixedTerm();
        assertEq(LPT.maxDeposit(LPT_ALICE_ADDRESS), MAX_TRANCHE_UNITS, "lptMaxDeposit must stay unbounded in a fixed term");
        uint256 remainingBptAssets = IERC20(POOL).balanceOf(LPT_ALICE_ADDRESS);
        assertGt(remainingBptAssets, 0, "arrange: BPT must remain for the fixed-term deposit");
        vm.startPrank(LPT_ALICE_ADDRESS);
        IERC20(POOL).approve(address(LPT), remainingBptAssets);
        uint256 fixedTermShares = LPT.deposit(toTrancheUnits(remainingBptAssets), LPT_ALICE_ADDRESS);
        vm.stopPrank();
        assertGt(fixedTermShares, 0, "the in-kind deposit must succeed in a fixed term");
        _assertCommittedConservation();
        _assertSolvency();

        // Only a pause zeroes the LPT deposit capacity
        _pauseKernel();
        assertEq(LPT.maxDeposit(LPT_ALICE_ADDRESS), ZERO_TRANCHE_UNITS, "lptMaxDeposit must report zero while paused");
    }

    /**
     * @notice A multi-asset LPT deposit whose senior leg overruns the coverage headroom reverts with
     *         `COVERAGE_REQUIREMENT_VIOLATED` and leaves the market untouched: the ST-leg flow is the only
     *         deposit besides the plain senior deposit that adds senior exposure, so it carries the same gate.
     * @dev The market is driven to the coverage brink with a plain senior deposit sized from the live
     *      `maxDeposit`, keeping a small pool-scaled headroom so the breaching venue add stays well within
     *      Balancer's unbalanced-add invariant bound.
     */
    function test_RevertIf_LPTDepositMultiAssetBreachesCoverage_atomic() public whenLPT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 25);
        _setupLPTProviders();
        uint256 poolLegAssets = testConfig.initialFunding / 50;
        _seedLPTBalanced(LPT_ALICE_ADDRESS, poolLegAssets);
        _sync();

        // Fill the coverage headroom down to a pool-scaled remainder
        uint256 headroomTargetAssets = poolLegAssets / 4;
        uint256 maxAssets = toUint256(ST.maxDeposit(ST_BOB_ADDRESS));
        assertLt(maxAssets, toUint256(MAX_TRANCHE_UNITS), "arrange: coverage must bound the senior deposit");
        assertGt(maxAssets, headroomTargetAssets, "arrange: the coverage headroom must exceed the target remainder");
        _doDepositST(ST_BOB_ADDRESS, maxAssets - headroomTargetAssets);

        uint256 breachAssets = toUint256(ST.maxDeposit(ST_BOB_ADDRESS)) + _stMaxDepositBreachSlackAssets();
        uint256 quoteAssets = _quoteAssetsForValue(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(breachAssets)));
        MarketSnapshot memory pre = _snap();
        assertLe(pre.liquidityUtilizationWAD, WAD, "arrange: liquidity must not be the binding gate");

        vm.startPrank(LPT_BOB_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(LPT), breachAssets);
        IERC20(testConfig.quoteAsset).approve(address(LPT), quoteAssets);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        IRoycoLiquidityProviderTranche(address(LPT)).depositMultiAsset(breachAssets, quoteAssets, 0, LPT_BOB_ADDRESS);
        vm.stopPrank();
        _assertMarketUnchanged(pre);
    }

    /**
     * @notice With the liquidity requirement already breached a multi-asset LPT deposit carrying a senior leg
     *         reverts with `LIQUIDITY_REQUIREMENT_VIOLATED` and leaves the market untouched, while coverage
     *         stays satisfied (liquidity is the binding gate).
     * @dev A small two-leg add cannot heal a deeply-breached requirement, so the post-op state stays above
     *      WAD and the ST-leg-enforced liquidity gate fires.
     */
    function test_RevertIf_LPTDepositMultiAssetBreachesLiquidity_atomic() public whenLPT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _seedDefaultLPT();
        _setMinLiquidityWAD(0.9e18);
        _sync();
        MarketSnapshot memory pre = _snap();
        assertGt(pre.liquidityUtilizationWAD, WAD, "arrange: the liquidity requirement must be breached");

        uint256 collateralAssets = testConfig.initialFunding / 1000;
        NAV_UNIT collateralValue = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(collateralAssets));
        uint256 quoteAssets = _quoteAssetsForValue(collateralValue);
        assertLe(
            _expectedCoverageUtilization(pre.lastCollateralNAV + collateralValue, ACCOUNTANT.getState().minCoverageWAD, pre.lastJTEffectiveNAV),
            WAD,
            "arrange: coverage must not be the binding gate"
        );
        // Even crediting both legs fully to the pooled depth, the post-op utilization stays breached
        assertGt(
            _expectedLiquidityUtilization(pre.lastSTEffectiveNAV + collateralValue, 0.9e18, pre.lastLPTRawNAV + collateralValue + collateralValue),
            WAD,
            "arrange: the deposit must not heal the breached requirement"
        );

        vm.startPrank(LPT_BOB_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(LPT), collateralAssets);
        IERC20(testConfig.quoteAsset).approve(address(LPT), quoteAssets);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        IRoycoLiquidityProviderTranche(address(LPT)).depositMultiAsset(collateralAssets, quoteAssets, 0, LPT_BOB_ADDRESS);
        vm.stopPrank();
        _assertMarketUnchanged(pre);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REDEMPTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    // ── Section-local helpers ──

    /**
     * @notice Derives a tranche's cumulative asset claims independently from the committed checkpoint plus pricing
     *         conversions, mirroring `TrancheClaimsLogic._deriveTrancheAssetClaims`.
     * @dev A tranche's claim IS its effective NAV converted once into the collateral asset, no raw-leg
     *      decomposition exists. The pricing conversions of the claim NAVs are inputs, not the function under test.
     *      Callers must have synced in the same block so the committed checkpoint equals the live state.
     */
    function _expectedTrancheClaims(TrancheType _trancheType) internal view returns (AssetClaims memory claims) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        if (_trancheType == TrancheType.LIQUIDITY_PROVIDER) {
            if (a.lastLPTRawNAV != ZERO_NAV_UNITS) claims.lptAssets = KERNEL.convertValueToLPTAssets(a.lastLPTRawNAV);
            claims.stShares = KERNEL.getState().lptOwnedSeniorTrancheShares;
            claims.nav = a.lastLPTRawNAV + _expectedValue(claims.stShares, ST.totalSupply(), a.lastSTEffectiveNAV);
            return claims;
        }
        claims.nav = _trancheType == TrancheType.SENIOR ? a.lastSTEffectiveNAV : a.lastJTEffectiveNAV;
        if (claims.nav != ZERO_NAV_UNITS) claims.collateralAssets = KERNEL.convertValueToCollateralAssets(claims.nav);
    }

    /// @notice Floor-scales every claims field by `_shares / (_totalShares + VIRTUAL_SHARES)`, mirroring
    ///         `TrancheClaimsLogic._scaleAssetClaims`, which now divides by the effective supply so a sole holder
    ///         can never redeem the whole tranche 1:1 (the virtual-share sliver stays behind).
    function _scaleExpectedClaims(AssetClaims memory _claims, uint256 _shares, uint256 _totalShares) internal pure returns (AssetClaims memory scaled) {
        uint256 effectiveTotalShares = _totalShares + VIRTUAL_SHARES;
        scaled.nav = toNAVUnits(Math.mulDiv(toUint256(_claims.nav), _shares, effectiveTotalShares));
        scaled.collateralAssets = toTrancheUnits(Math.mulDiv(toUint256(_claims.collateralAssets), _shares, effectiveTotalShares));
        scaled.lptAssets = toTrancheUnits(Math.mulDiv(toUint256(_claims.lptAssets), _shares, effectiveTotalShares));
        scaled.stShares = Math.mulDiv(_claims.stShares, _shares, effectiveTotalShares);
    }

    /**
     * @notice Applies the expected ST self-liquidation bonus to a redeemer's base claims, mirroring
     *         `SelfLiquidationLogic.applySeniorTrancheSelfLiquidationBonus` on the committed checkpoint.
     * @dev The sized bonus is `min(floor(nav * bonusWAD / WAD), jtEffectiveNAV, maxUtilizationNeutralBonus)` with
     *      the neutral cap `floor(nav * jtEffectiveNAV / stEffectiveNAV)` (under conservation the collateral NAV
     *      minus jtEffectiveNAV IS stEffectiveNAV), granted in the collateral asset, and the returned bonus NAV
     *      is the value of the assets actually granted (a single collateral round trip, the src quantization).
     *      Pricing conversions of the claim legs are inputs. Callers must have synced in the same block.
     */
    function _expectedClaimsWithSelfLiquidationBonus(AssetClaims memory _userClaims)
        internal
        view
        returns (AssetClaims memory claimsWithBonus, NAV_UNIT bonusNAV)
    {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 coverageUtilizationWAD = _expectedCoverageUtilization(a.lastCollateralNAV, a.minCoverageWAD, a.lastJTEffectiveNAV);
        if (coverageUtilizationWAD < a.coverageLiquidationUtilizationWAD) return (_userClaims, ZERO_NAV_UNITS);

        uint256 jtEffectiveNAV = toUint256(a.lastJTEffectiveNAV);
        uint256 desiredBonus = Math.mulDiv(toUint256(_userClaims.nav), KERNEL.getState().stSelfLiquidationBonusWAD, WAD);

        // The maximum bonus that does not raise coverage utilization (the bank-run-neutral cap)
        uint256 maxNeutralBonus;
        if (toUint256(_userClaims.nav) != 0) {
            maxNeutralBonus = Math.mulDiv(toUint256(_userClaims.nav), jtEffectiveNAV, toUint256(a.lastSTEffectiveNAV));
        }

        uint256 bonus = Math.min(Math.min(desiredBonus, jtEffectiveNAV), maxNeutralBonus);
        if (bonus == 0) return (_userClaims, ZERO_NAV_UNITS);
        TRANCHE_UNIT bonusAssets = KERNEL.convertValueToCollateralAssets(toNAVUnits(bonus));
        // Report the bonus at the value of the assets actually granted, mirroring the src quantization
        bonusNAV = KERNEL.convertCollateralAssetsToValue(bonusAssets);
        claimsWithBonus.collateralAssets = _userClaims.collateralAssets + bonusAssets;
        claimsWithBonus.nav = _userClaims.nav + bonusNAV;
    }

    /**
     * @notice The smallest junior redemption NAV guaranteed to leave coverage utilization above WAD, from the
     *         committed checkpoint plus a documented drift margin.
     * @dev Derivation (post coverageUtilizationWAD > WAD, the gate rounds up in favor of breach): redeeming `x` NAV removes
     *      the full `x` from the collateral NAV `E`, so the exact boundary solves `(E - x)*minCov > (J - x)*WAD`, giving
     *      `x > (J*WAD - E*minCov) / (WAD - minCov)`. The margin adds the single dust tolerance plus two
     *      `maxNAVDelta()` pricing round-trips (claim NAV -> collateral assets -> measured collateral delta) plus
     *      two wei, so the realized removal strictly dominates the boundary. Requires pre coverageUtilizationWAD <= WAD.
     */
    function _jtCoverageBreachRedemptionNAV() internal view returns (uint256 breachNAV) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 jtEffectiveNAV = toUint256(a.lastJTEffectiveNAV);
        uint256 collateralNAV = toUint256(a.lastCollateralNAV);

        uint256 boundary = Math.ceilDiv(jtEffectiveNAV * WAD - collateralNAV * a.minCoverageWAD, WAD - a.minCoverageWAD);
        breachNAV = boundary + toUint256(a.dustTolerance) + 2 * toUint256(maxNAVDelta()) + 2;
    }

    /// @notice Asserts field-by-field equality of two `AssetClaims`.
    function _assertClaimsEq(AssetClaims memory _actual, AssetClaims memory _expected, string memory _ctx) internal pure {
        assertEq(_actual.collateralAssets, _expected.collateralAssets, string.concat(_ctx, ": collateralAssets claim"));
        assertEq(_actual.lptAssets, _expected.lptAssets, string.concat(_ctx, ": lptAssets claim"));
        assertEq(_actual.stShares, _expected.stShares, string.concat(_ctx, ": stShares claim"));
        assertEq(_actual.nav, _expected.nav, string.concat(_ctx, ": claim NAV"));
    }

    /// @notice Asserts the receiver's collateral balance grew by exactly the collateral asset claim.
    function _assertCollateralClaimsPaid(address _receiver, uint256 _collateralBalPre, AssetClaims memory _claims) internal view {
        assertEq(
            IERC20(COLLATERAL_ASSET).balanceOf(_receiver) - _collateralBalPre,
            toUint256(_claims.collateralAssets),
            "receiver must be paid the collateral asset claim exactly"
        );
    }

    /**
     * @notice Arranges the LPT state shared by the staged-premium redemption tests: seeded ST/JT market, a deliberately
     *         dust-sized LPT pool, overlay on with the liquidity utilization near its target, and a staged idle liquidity premium.
     * @dev The pool is sized to roughly 1/10000 of the funding so the accrued premium overruns the venue's unbalanced-add
     *      invariant-ratio cap and the single-sided reinvestment reverts, staying idle. The zero-slippage seam inside
     *      `_stageIdleLiquidityPremium` is a second belt (on this venue the BPT oracle can mark under the mint rate, so the
     *      slippage gate alone does not guarantee staging). The minimum liquidity is sized so utilization sits at about
     *      80 percent, keeping the LDM paying while leaving the redemption tests headroom under the 100 percent gate.
     */
    function _arrangeLPTWithStagedIdleLiquidityPremium() internal returns (uint256 idleShares) {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _setupLPTProviders();
        uint256 collateralLegAssets = testConfig.initialFunding / 10_000;
        _seedLPTBalanced(LPT_ALICE_ADDRESS, collateralLegAssets);
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.8e18);
        _enableLPTOverlay(0.1e18, 0.5e18, minLiquidityWAD);
        idleShares = _stageIdleLiquidityPremium();
        _sync();
    }

    // ── ST redemptions ──

    /**
     * @notice An ST redemption pays exactly the per-field floor-scaled slice of the senior tranche's
     *         single-conversion claims, debits the owned-asset ledger by the claims, and books the measured
     *         redemption NAV out of the committed senior effective NAV, with an exact-args `Redeem` event.
     */
    function test_STRedeem_exactClaimScaling() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applySTYield(0.05e18);
        _sync();

        uint256 stSupply = ST.totalSupply();
        uint256 shares = ST.balanceOf(ST_ALICE_ADDRESS) / 2;
        AssetClaims memory expectedClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.SENIOR), shares, stSupply);
        assertGt(toUint256(expectedClaims.collateralAssets), 0, "arrange: the redemption must claim collateral assets");
        MarketSnapshot memory pre = _snap();
        uint256 collateralBalPre = IERC20(COLLATERAL_ASSET).balanceOf(ST_ALICE_ADDRESS);

        vm.startPrank(ST_ALICE_ADDRESS);
        _expectRedeem(address(ST), ST_ALICE_ADDRESS, ST_ALICE_ADDRESS, expectedClaims, shares);
        AssetClaims memory claims = ST.redeem(shares, ST_ALICE_ADDRESS, ST_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        _assertClaimsEq(claims, expectedClaims, "executed claims");
        // Counterweight independent of the claim-scaling mirror: the payout can never exceed the exact pro-rata
        // slice of the pre-redemption senior effective NAV, so repeated redemptions cannot round-steal value.
        _assertClaimsWithinProRataCeiling(claims, shares, stSupply, pre.lastSTEffectiveNAV);
        _assertCollateralClaimsPaid(ST_ALICE_ADDRESS, collateralBalPre, expectedClaims);
        MarketSnapshot memory post = _snap();
        assertEq(post.stSupply, pre.stSupply - shares, "ST supply must fall by exactly the redeemed shares");
        assertEq(post.collateralOwned, pre.collateralOwned - expectedClaims.collateralAssets, "collateralOwned must fall by the collateral asset claim");
        NAV_UNIT redemptionNAV = pre.lastCollateralNAV - post.lastCollateralNAV;
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
        uint256 collateralBalPre = IERC20(COLLATERAL_ASSET).balanceOf(ST_BOB_ADDRESS);
        vm.prank(ST_BOB_ADDRESS);
        AssetClaims memory claims = ST.redeem(shares, ST_BOB_ADDRESS, ST_ALICE_ADDRESS);
        _assertSolvency();

        _assertClaimsEq(claims, expectedClaims, "allowance-path claims");
        assertEq(ST.allowance(ST_ALICE_ADDRESS, ST_BOB_ADDRESS), 0, "the exact allowance must be consumed to zero");
        assertEq(ST.balanceOf(ST_ALICE_ADDRESS), aliceSharesPre - shares, "the owner's shares must be burned");
        _assertCollateralClaimsPaid(ST_BOB_ADDRESS, collateralBalPre, expectedClaims);
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
        NAV_UNIT redemptionNAV = pre.lastCollateralNAV - post.lastCollateralNAV;
        assertEq(
            post.lastSTEffectiveNAV,
            pre.lastSTEffectiveNAV - (redemptionNAV - bonusNAV),
            "the senior effective NAV must fall by the redemption net of the bonus"
        );
        assertLe(post.coverageUtilizationWAD, pre.coverageUtilizationWAD, "the bonus must never raise coverage utilization");
        // Counterweights independent of the bonus mirror, on measured quantities only: the junior drain (the bonus
        // actually funded) must stay within the configured bonus fraction of the paid claim, the desired bonus is
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
     * @notice `stMaxRedeem` is bounded only by the collateral NAV, so a sole senior LP can redeem its full balance
     *         and the claims stay within the owned-asset ledger.
     * @dev Derivation: the share bound is `T * collateralNAV / stEffectiveNAV` with `stEffectiveNAV <= collateralNAV`
     *      under conservation, so the bound is at least the total supply and the owner's balance is the binding term.
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
        assertLe(expectedClaims.collateralAssets, pre.collateralOwned, "the collateral asset claim must stay within the owned collateral assets");

        OpReceipt memory r = _doRedeemST(ST_ALICE_ADDRESS, maxShares);
        _assertClaimsEq(r.claims, expectedClaims, "max-redemption claims");
        assertEq(r.post.stSupply, pre.stSupply - maxShares, "ST supply must fall by exactly the redeemed shares");
        assertEq(ST.balanceOf(ST_ALICE_ADDRESS), 0, "the redeemer must exit fully");
        _assertCommittedConservation();
    }

    /// @notice With the liquidity requirement breached a senior redemption still succeeds and pays its exact
    ///         scaled claims: senior exits are never liquidity-gated (the no-run guarantee's exempt direction).
    function test_STRedeem_liquidityBreach_notGated() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
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
     * @notice A JT redemption pays exactly the per-field floor-scaled slice of the junior tranche's
     *         single-conversion claims, matches `previewRedeem` exactly, and books the measured redemption NAV
     *         out of the committed junior effective NAV.
     */
    function test_JTRedeem_exactClaimScaling_andPreviewParity() public {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _applyJTYield(0.05e18);
        _sync();

        uint256 jtSupply = JT.totalSupply();
        uint256 shares = JT.balanceOf(JT_ALICE_ADDRESS) / 2;
        AssetClaims memory expectedClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.JUNIOR), shares, jtSupply);
        assertGt(toUint256(expectedClaims.collateralAssets), 0, "arrange: the redemption must claim collateral assets");
        AssetClaims memory previewClaims = JT.previewRedeem(shares);
        _assertClaimsEq(previewClaims, expectedClaims, "previewRedeem vs the independent derivation");
        MarketSnapshot memory pre = _snap();
        uint256 collateralBalPre = IERC20(COLLATERAL_ASSET).balanceOf(JT_ALICE_ADDRESS);

        vm.startPrank(JT_ALICE_ADDRESS);
        _expectRedeem(address(JT), JT_ALICE_ADDRESS, JT_ALICE_ADDRESS, expectedClaims, shares);
        AssetClaims memory claims = JT.redeem(shares, JT_ALICE_ADDRESS, JT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        _assertClaimsEq(claims, expectedClaims, "executed claims");
        // Counterweight independent of the claim-scaling mirror: the payout can never exceed the exact pro-rata
        // slice of the pre-redemption junior effective NAV.
        _assertClaimsWithinProRataCeiling(claims, shares, jtSupply, pre.lastJTEffectiveNAV);
        _assertCollateralClaimsPaid(JT_ALICE_ADDRESS, collateralBalPre, expectedClaims);
        MarketSnapshot memory post = _snap();
        assertEq(post.jtSupply, pre.jtSupply - shares, "JT supply must fall by exactly the redeemed shares");
        assertEq(post.collateralOwned, pre.collateralOwned - expectedClaims.collateralAssets, "collateralOwned must fall by the collateral asset claim");
        NAV_UNIT redemptionNAV = pre.lastCollateralNAV - post.lastCollateralNAV;
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV - redemptionNAV, "the junior effective NAV must fall by exactly the measured redemption NAV");
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV, "the senior effective NAV must be untouched");
        assertEq(post.lastJTImpermanentLoss, pre.lastJTImpermanentLoss, "no impermanent loss may move on a redemption without IL");
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
    function test_JTRedeem_liquidityBreach_notGated() public whenLPT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _seedDefaultLPT();
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
     * @notice A dust-classified loss from PERPETUAL is erased at commit (reset event, market stays PERPETUAL),
     *         the next gain settles as a plain fee-gated gain rather than a recovery, and a junior redemption
     *         carries no impermanent loss ledger to scale.
     * @dev Replaces the retained-dust-IL scaling vector: PERPETUAL with a nonzero IL is unrepresentable (every
     *      PERPETUAL commit erases), so the old proportional-recovery claim no longer exists to redeem. The
     *      0.1 percent collateral loss books its whole magnitude as IL inside the waterfall (the JT-attributed
     *      residual directly, the ST-attributed leg via coverage), so a 1 percent dust tolerance classifies it
     *      as dust and the commit erases it with the exact-args reset event.
     */
    function test_JTRedeem_dustLossErasedOnPerpetualCommit_noILToScale() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 2);
        _setFixedTermDuration(7 days);
        _sync();
        _raiseDustTolerance(toNAVUnits(toUint256(ACCOUNTANT.getState().lastCollateralNAV) / 100));
        _applySTLoss(0.001e18);

        // The waterfall books the dust loss as IL, then the PERPETUAL commit erases exactly that amount
        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(toUint256(e.jtImpermanentLoss), 0, "arrange: the dust loss must book an impermanent loss inside the waterfall");
        assertLe(e.jtImpermanentLoss, ACCOUNTANT.getState().dustTolerance, "arrange: the booked loss must classify as dust");
        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(e.jtImpermanentLoss);
        SyncedAccountingState memory state = _syncWithState();
        _assertSyncMatchesExpectation(state, e);

        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertTrue(a.lastMarketState == MarketState.PERPETUAL, "the dust-classified loss must keep the market perpetual");
        assertEq(a.lastJTImpermanentLoss, ZERO_NAV_UNITS, "the perpetual commit must erase the dust impermanent loss");
        assertEq(state.jtImpermanentLoss, ZERO_NAV_UNITS, "the returned packet must carry the erased impermanent loss");

        // The next gain is a plain gain, fee-gated on the dust tolerance, never a recovery of the erased IL
        _warpForward(1 days);
        _applySTYield(0.05e18);
        SyncExpectation memory eGain = _buildSyncExpectation(false);
        assertEq(eGain.lastJTImpermanentLoss, ZERO_NAV_UNITS, "arrange: no impermanent loss may carry into the gain window");
        assertGt(toUint256(eGain.jtProtocolFee), 0, "the plain junior gain above dust must accrue its fee");
        SyncedAccountingState memory gainState = _syncWithState();
        _assertSyncMatchesExpectation(gainState, eGain);

        // A junior redemption settles with no impermanent loss ledger to move
        OpReceipt memory r = _doRedeemJT(JT_ALICE_ADDRESS, JT.balanceOf(JT_ALICE_ADDRESS) / 4);
        NAV_UNIT redemptionNAV = r.pre.lastCollateralNAV - r.post.lastCollateralNAV;
        assertEq(
            r.post.lastJTEffectiveNAV, r.pre.lastJTEffectiveNAV - redemptionNAV, "the junior effective NAV must fall by exactly the measured redemption NAV"
        );
        assertEq(r.post.lastJTImpermanentLoss, ZERO_NAV_UNITS, "no impermanent loss may exist for a perpetual junior exit");
        _assertCommittedConservation();
    }

    // ── LPT redemptions ──

    /**
     * @notice An in-kind LPT redemption pays the proportional BPT slice plus the pro-rata slice of the staged idle
     *         premium senior shares directly to the redeemer, with exact per-field floor scaling and an exact-args
     *         `Redeem` event.
     */
    function test_LPTRedeem_inKind_paysBPTAndIdleSliceDirectly() public whenLPT {
        uint256 idleShares = _arrangeLPTWithStagedIdleLiquidityPremium();

        uint256 lptSupply = LPT.totalSupply();
        AssetClaims memory totalClaims = _expectedTrancheClaims(TrancheType.LIQUIDITY_PROVIDER);
        assertEq(totalClaims.stShares, idleShares, "arrange: the idle ledger must back the claims");
        uint256 shares = LPT.balanceOf(LPT_ALICE_ADDRESS) / 8;
        AssetClaims memory expectedClaims = _scaleExpectedClaims(totalClaims, shares, lptSupply);
        assertGt(toUint256(expectedClaims.lptAssets), 0, "arrange: the redemption must claim a BPT slice");
        assertGt(expectedClaims.stShares, 0, "arrange: the redemption must claim an idle liquidity premium slice");
        MarketSnapshot memory pre = _snap();
        uint256 bptBalPre = IERC20(POOL).balanceOf(LPT_ALICE_ADDRESS);
        uint256 stShareBalPre = ST.balanceOf(LPT_ALICE_ADDRESS);
        NAV_UNIT lptEffPre = LPT.totalAssets().nav; // the production live LPT mark, captured as a ceiling input

        vm.startPrank(LPT_ALICE_ADDRESS);
        _expectRedeem(address(LPT), LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS, expectedClaims, shares);
        AssetClaims memory claims = LPT.redeem(shares, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        _assertClaimsEq(claims, expectedClaims, "executed claims");
        // Counterweight independent of the claim-scaling mirror: the payout can never exceed the exact pro-rata
        // slice of the tranche's own pre-redemption effective NAV (padded one pricing round-trip, since the live
        // BPT valuation can drift a floor's worth from the committed mark the claims were derived on).
        _assertClaimsWithinProRataCeiling(claims, shares, lptSupply, lptEffPre + maxNAVDelta());
        MarketSnapshot memory post = _snap();
        assertEq(IERC20(POOL).balanceOf(LPT_ALICE_ADDRESS) - bptBalPre, toUint256(expectedClaims.lptAssets), "the BPT slice must be paid in kind");
        assertEq(
            ST.balanceOf(LPT_ALICE_ADDRESS) - stShareBalPre, expectedClaims.stShares, "the idle liquidity premium slice must be paid as senior shares directly"
        );
        assertEq(post.lptOwned, pre.lptOwned - expectedClaims.lptAssets, "lptOwned must fall by the BPT slice");
        assertEq(
            post.lptOwnedSeniorTrancheShares,
            pre.lptOwnedSeniorTrancheShares - expectedClaims.stShares,
            "the idle liquidity premium ledger must fall by the paid slice"
        );
        assertEq(post.lptSupply, pre.lptSupply - shares, "LPT supply must fall by exactly the redeemed shares");
        assertEq(post.lastLPTRawNAV, KERNEL.convertLPTAssetsToValue(post.lptOwned), "the committed LPT mark must be the fresh venue mark");
        assertLt(post.lastLPTRawNAV, pre.lastLPTRawNAV, "the committed LPT mark must fall");
        assertEq(post.lastCollateralNAV, pre.lastCollateralNAV, "moving idle senior shares must not move the collateral NAV");
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV, "moving idle senior shares must not move the senior effective NAV");
        assertLe(post.liquidityUtilizationWAD, WAD, "the redemption must leave the liquidity requirement satisfied");
        _assertCommittedConservation();
    }

    /// @notice Both LPT redemption previews (in-kind view and multi-asset query-mode) equal execution exactly per
    ///         field in the same block, with staged idle liquidity premium in play.
    function test_LPTRedeem_previewParity_inKindAndMultiAsset() public whenLPT {
        _arrangeLPTWithStagedIdleLiquidityPremium();
        uint256 shares = LPT.balanceOf(LPT_ALICE_ADDRESS) / 10;

        AssetClaims memory previewInKindClaims = LPT.previewRedeem(shares);
        uint256 snapshotId = vm.snapshotState();
        OpReceipt memory rInKind = _doRedeemLPT(LPT_ALICE_ADDRESS, shares);
        _assertClaimsEq(rInKind.claims, previewInKindClaims, "in-kind previewRedeem parity");
        assertGt(toUint256(rInKind.claims.lptAssets), 0, "the in-kind redemption must pay a BPT slice");
        _assertCommittedConservation();
        vm.revertToState(snapshotId);

        (AssetClaims memory previewMultiClaims, uint256 previewQuoteAssets) = _previewRedeemLPTMulti(shares);
        OpReceipt memory rMulti = _doRedeemLPTMulti(LPT_ALICE_ADDRESS, shares, 0, 0);
        _assertClaimsEq(rMulti.claims, previewMultiClaims, "multi-asset previewRedeem parity");
        assertEq(rMulti.quoteAssets, previewQuoteAssets, "the previewed quote assets must equal execution exactly");
        assertGt(rMulti.quoteAssets, 0, "the multi-asset redemption must pay quote assets");
        _assertCommittedConservation();
    }

    /// @notice An LPT redemption that would pull the pooled depth below the senior liquidity floor reverts with
    ///         `LIQUIDITY_REQUIREMENT_VIOLATED` and leaves the market untouched.
    function test_RevertIf_LPTRedeemBreachesLiquidityGate() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.9e18);
        _setMinLiquidityWAD(minLiquidityWAD);
        _sync();

        MarketSnapshot memory pre = _snap();
        assertLe(pre.liquidityUtilizationWAD, WAD, "arrange: the gate must start open");
        assertGt(pre.liquidityUtilizationWAD, WAD / 2, "arrange: utilization must sit near the gate");
        uint256 shares = LPT.balanceOf(LPT_ALICE_ADDRESS) / 2;
        _assertSliceWouldBreachLiquidity(shares, minLiquidityWAD, pre);

        vm.prank(LPT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        LPT.redeem(shares, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);
        _assertMarketUnchanged(pre);
    }

    /**
     * @notice A breached liquidation coverage utilization does NOT waive the in-kind liquidity gate: `maxRedeem`
     *         stays bounded below the holder's full balance and an in-kind redemption that would strand the pool
     *         below the senior floor reverts LIQUIDITY_REQUIREMENT_VIOLATED.
     */
    function test_LPTRedeem_liquidationBreach_enforcesLiquidityGate() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.9e18);
        _setMinLiquidityWAD(minLiquidityWAD);
        _breachLiquidation();

        MarketSnapshot memory pre = _snap();
        assertGe(pre.coverageUtilizationWAD, ACCOUNTANT.getState().coverageLiquidationUtilizationWAD, "arrange: the liquidation threshold must be breached");
        uint256 shares = (LPT.balanceOf(LPT_ALICE_ADDRESS) * 3) / 4;
        _assertSliceWouldBreachLiquidity(shares, minLiquidityWAD, pre);
        assertLt(LPT.maxRedeem(LPT_ALICE_ADDRESS), LPT.balanceOf(LPT_ALICE_ADDRESS), "the liquidation breach must not waive the in-kind liquidity gate");

        // The in-kind redemption only shrinks the pool depth, so it cannot relax its own floor and reverts
        vm.prank(LPT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        LPT.redeem(shares, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);
        _assertMarketUnchanged(pre);
    }

    /**
     * @notice `lptMaxRedeem` inverts the liquidity gate: the max-size redemption lands under it and the same
     *         redemption plus the documented slack reverts.
     * @dev Breach slack derivation: `maxLPTWithdrawal` under-reports the exact boundary by the dust tolerance
     *      plus at most one wei of ceiling drift, and the realized venue-mark drop can undershoot the
     *      scaled claim value by up to two pricing round-trips, so the slack is that dust plus two `maxNAVDelta()`
     *      plus two wei, converted to LPT shares at the committed mark (ceiling) plus two shares for share floors.
     */
    function test_LPTRedeem_maxRedeemExactlyRedeemable() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.5e18);
        _setMinLiquidityWAD(minLiquidityWAD);
        _sync();

        uint256 maxShares = LPT.maxRedeem(LPT_ALICE_ADDRESS);
        assertGt(maxShares, 0, "arrange: the liquidity surplus must be redeemable");
        assertLt(maxShares, LPT.balanceOf(LPT_ALICE_ADDRESS), "arrange: the liquidity requirement must bound the redemption");

        uint256 snapshotId = vm.snapshotState();
        OpReceipt memory r = _doRedeemLPT(LPT_ALICE_ADDRESS, maxShares);
        assertLe(r.post.liquidityUtilizationWAD, WAD, "a max-size LPT redemption must leave the liquidity requirement satisfied");
        _assertCommittedConservation();
        vm.revertToState(snapshotId);

        IRoycoDayAccountant.RoycoDayAccountantState memory a2 = ACCOUNTANT.getState();
        uint256 slackValue = toUint256(a2.dustTolerance) + 2 * toUint256(maxNAVDelta()) + 2;
        uint256 breachShares = maxShares + Math.mulDiv(slackValue, LPT.totalSupply(), toUint256(a2.lastLPTRawNAV), Math.Rounding.Ceil) + 2;
        assertLe(breachShares, LPT.balanceOf(LPT_ALICE_ADDRESS), "arrange: the breach redemption must be affordable");

        vm.prank(LPT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        LPT.redeem(breachShares, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);
    }

    /**
     * @notice A multi-asset LPT redemption unwinds the senior leg to the receiver in underlying, pays the quote
     *         straight through, burns the venue-withdrawn plus idle senior shares, emits an exact-args
     *         `MultiAssetRedeem`, and a quote min-out breach reverts inside Balancer leaving the market untouched.
     * @dev Event and balance expectations reuse the query-mode preview, whose exactness against execution is pinned
     *      by the parity test. The min-out breach asserts Balancer's exact `AmountOutBelowMin` args. No
     *      deadline parameter exists on this surface.
     */
    function test_LPTRedeemMultiAsset_unwindsSeniorLeg_minOutsAndEvent() public whenLPT {
        _arrangeLPTWithStagedIdleLiquidityPremium();

        uint256 lptSupply = LPT.totalSupply();
        uint256 shares = LPT.balanceOf(LPT_ALICE_ADDRESS) / 8;
        AssetClaims memory expectedLPTClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.LIQUIDITY_PROVIDER), shares, lptSupply);
        assertGt(expectedLPTClaims.stShares, 0, "arrange: the redemption must carry an idle liquidity premium slice");
        (AssetClaims memory previewClaims, uint256 previewQuoteAssets) = _previewRedeemLPTMulti(shares);
        assertGt(previewQuoteAssets, 0, "arrange: the redemption must pay quote assets");

        uint256 snapshotId = vm.snapshotState();
        MarketSnapshot memory pre = _snap();
        uint256 quoteBalPre = IERC20(testConfig.quoteAsset).balanceOf(LPT_ALICE_ADDRESS);
        uint256 kernelQuoteBalPre = IERC20(testConfig.quoteAsset).balanceOf(address(KERNEL));
        uint256 collateralBalPre = IERC20(COLLATERAL_ASSET).balanceOf(LPT_ALICE_ADDRESS);

        vm.startPrank(LPT_ALICE_ADDRESS);
        vm.expectEmit(true, true, true, true, address(LPT));
        emit IRoycoLiquidityProviderTranche.MultiAssetRedeem(LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS, shares, previewClaims, previewQuoteAssets);
        (AssetClaims memory claims, uint256 quoteAssets) =
            IRoycoLiquidityProviderTranche(address(LPT)).redeemMultiAsset(shares, 0, previewQuoteAssets, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        _assertClaimsEq(claims, previewClaims, "executed multi-asset claims");
        assertEq(quoteAssets, previewQuoteAssets, "the executed quote assets must equal the preview");
        MarketSnapshot memory post = _snap();
        assertEq(IERC20(testConfig.quoteAsset).balanceOf(LPT_ALICE_ADDRESS) - quoteBalPre, previewQuoteAssets, "the quote must go straight to the receiver");
        assertEq(IERC20(testConfig.quoteAsset).balanceOf(address(KERNEL)), kernelQuoteBalPre, "the kernel must never custody the quote leg");
        _assertCollateralClaimsPaid(LPT_ALICE_ADDRESS, collateralBalPre, previewClaims);
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal - expectedLPTClaims.stShares, "the kernel's held senior shares must fall by the idle slice");
        assertEq(
            post.lptOwnedSeniorTrancheShares,
            pre.lptOwnedSeniorTrancheShares - expectedLPTClaims.stShares,
            "the idle liquidity premium ledger must fall by the idle slice"
        );
        assertEq(post.lptOwned, pre.lptOwned - expectedLPTClaims.lptAssets, "lptOwned must fall by the BPT slice");
        assertEq(post.lptSupply, pre.lptSupply - shares, "LPT supply must fall by exactly the redeemed shares");
        uint256 stSharesBurned = pre.stSupply - post.stSupply;
        assertGt(stSharesBurned, expectedLPTClaims.stShares, "the venue-withdrawn senior shares must be burned on top of the idle slice");
        NAV_UNIT redemptionNAV = pre.lastCollateralNAV - post.lastCollateralNAV;
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV - redemptionNAV, "the senior effective NAV must fall by exactly the measured redemption NAV");
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV, "the junior effective NAV must be untouched with no liquidation bonus");
        assertApproxEqAbs(redemptionNAV, previewClaims.nav, maxNAVDelta(), "the measured redemption NAV must round-trip the claim NAV");
        assertLe(post.liquidityUtilizationWAD, WAD, "the redemption must leave the liquidity requirement satisfied");
        _assertCommittedConservation();

        // A quote min-out one wei above the removal's output reverts inside Balancer and the market is untouched
        vm.revertToState(snapshotId);
        MarketSnapshot memory preBreach = _snap();
        vm.startPrank(LPT_ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.AmountOutBelowMin.selector, testConfig.quoteAsset, previewQuoteAssets, previewQuoteAssets + 1));
        IRoycoLiquidityProviderTranche(address(LPT)).redeemMultiAsset(shares, 0, previewQuoteAssets + 1, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertMarketUnchanged(preBreach);
    }

    /// @notice A zero-share LPT redemption reverts with `MUST_REQUEST_NON_ZERO_SHARES` on both the in-kind and the
    ///         multi-asset flow.
    function test_RevertIf_LPTRedeemZeroShares() public whenLPT {
        _setupLPTProviders();
        vm.prank(LPT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector);
        LPT.redeem(0, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);

        vm.prank(LPT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector);
        IRoycoLiquidityProviderTranche(address(LPT)).redeemMultiAsset(0, 0, 0, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);
    }

    /// @notice In a fixed-term market both LPT redemption flows revert with `DISABLED_IN_FIXED_TERM_STATE`,
    ///         `maxRedeem` and `maxRedeemMultiAsset` report zero, and both previews bubble the exact exec
    ///         revert (preview == exec).
    function test_RevertIf_LPTRedeemInFixedTerm() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
        uint256 shares = LPT.balanceOf(LPT_ALICE_ADDRESS) / 2;
        _enterFixedTerm();

        assertEq(LPT.maxRedeem(LPT_ALICE_ADDRESS), 0, "lptMaxRedeem must report zero in a fixed term");
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        LPT.previewRedeem(shares);
        assertEq(
            IRoycoLiquidityProviderTranche(address(LPT)).maxRedeemMultiAsset(LPT_ALICE_ADDRESS), 0, "lptMaxRedeemMultiAsset must report zero in a fixed term"
        );
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        IRoycoLiquidityProviderTranche(address(LPT)).previewRedeemMultiAsset(shares);

        vm.prank(LPT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        LPT.redeem(shares, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);

        vm.prank(LPT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        IRoycoLiquidityProviderTranche(address(LPT)).redeemMultiAsset(shares, 0, 0, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);
    }

    /**
     * @notice A multi-asset LPT redemption whose senior-share min-out exceeds the venue withdrawal reverts inside
     *         Balancer with the exact-args `AmountOutBelowMin` on the senior share token and leaves the market
     *         untouched (atomicity).
     * @dev The venue's senior-share withdrawal is measured by a snapshot-reverted execution probe (the burned
     *      supply delta, exactly the venue leg with no idle liquidity premium staged), which is deterministic against the
     *      identical same-block state the breach call then sees.
     */
    function test_RevertIf_LPTRedeemMultiAssetMinSTSharesOutBreached_atomic() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
        _sync();
        uint256 shares = LPT.balanceOf(LPT_ALICE_ADDRESS) / 4;
        MarketSnapshot memory pre = _snap();
        assertEq(pre.lptOwnedSeniorTrancheShares, 0, "arrange: no staged premium may exist");

        uint256 snapshotId = vm.snapshotState();
        vm.prank(LPT_ALICE_ADDRESS);
        IRoycoLiquidityProviderTranche(address(LPT)).redeemMultiAsset(shares, 0, 0, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);
        uint256 venueSTSharesOut = pre.stSupply - ST.totalSupply();
        vm.revertToState(snapshotId);
        assertGt(venueSTSharesOut, 0, "arrange: the venue must withdraw senior shares");

        vm.prank(LPT_ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.AmountOutBelowMin.selector, address(ST), venueSTSharesOut, venueSTSharesOut + 1));
        IRoycoLiquidityProviderTranche(address(LPT)).redeemMultiAsset(shares, venueSTSharesOut + 1, 0, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);
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
        assertEq(uint256(a.twLPTYieldShareAccruedWAD), 0, "flush: the LPT accrual accumulator must reset");
        assertEq(uint256(a.lastYieldShareAccrualTimestamp), uint256(a.lastPremiumPaymentTimestamp), "flush: the accrual and premium windows must coincide");
    }

    /**
     * @notice Builds and computes the independent sync expectation for the sync about to execute, from
     *         the committed checkpoint, the sync-time YDM previews, and the measured collateral NAV.
     * @dev Must be called in the sync's own block, after every warp and simulate, so the previews and the
     *      elapsed window match what the sync will use. The stored time-weighted accumulators and both window
     *      starts are carried as inputs, so a window with residual unpaid accrual (an earlier non-paying sync,
     *      an admin warp, or a warp-required loss hook) prices exactly like production. The collateral NAV and
     *      YDM previews are sync inputs, not the code under test.
     */
    function _buildSyncExpectation(bool _fixedTermActive) internal returns (SyncExpectation memory e) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        e.twJTStart = uint256(a.twJTYieldShareAccruedWAD);
        e.twLPTStart = uint256(a.twLPTYieldShareAccruedWAD);
        e.premiumElapsed = block.timestamp - a.lastPremiumPaymentTimestamp;

        e.jtYieldShareWAD = _previewYieldShareAsAccountant(
            a.jtYDM, a.lastMarketState, _expectedCoverageUtilization(a.lastCollateralNAV, a.minCoverageWAD, a.lastJTEffectiveNAV), a.maxJTYieldShareWAD
        );
        e.lptYieldShareWAD = a.maxLPTYieldShareWAD == 0
            ? 0
            : _previewYieldShareAsAccountant(
                a.lptYDM, a.lastMarketState, _expectedLiquidityUtilization(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLPTRawNAV), a.maxLPTYieldShareWAD
            );
        e.elapsed = block.timestamp - a.lastYieldShareAccrualTimestamp;
        (e.collateralNAVNew,) = _measureFreshSyncInputs(ZERO_TRANCHE_UNITS);
        e.lastCollateralNAV = a.lastCollateralNAV;
        e.lastSTEffectiveNAV = a.lastSTEffectiveNAV;
        e.lastJTEffectiveNAV = a.lastJTEffectiveNAV;
        e.lastJTImpermanentLoss = a.lastJTImpermanentLoss;
        e.stProtocolFeeWAD = a.stProtocolFeeWAD;
        e.jtProtocolFeeWAD = a.jtProtocolFeeWAD;
        e.jtYieldShareProtocolFeeWAD = a.jtYieldShareProtocolFeeWAD;
        e.lptYieldShareProtocolFeeWAD = a.lptYieldShareProtocolFeeWAD;
        e.dustTolerance = a.dustTolerance;
        e.fixedTermActive = _fixedTermActive;
        e = _expectedSync(e);
    }

    /// @notice Asserts the executed sync's returned packet and committed checkpoint against the independent
    ///         sync expectation, plus wei-exact committed conservation.
    function _assertSyncMatchesExpectation(SyncedAccountingState memory _state, SyncExpectation memory _e) internal view {
        assertEq(_state.stEffectiveNAV, _e.stEffectiveNAV, "returned ST effective NAV vs the independent recomputation");
        assertEq(_state.jtEffectiveNAV, _e.jtEffectiveNAV, "returned JT effective NAV vs the independent recomputation");
        assertEq(_state.lptLiquidityPremium, _e.lptLiquidityPremium, "returned LPT liquidity premium vs the independent recomputation");
        assertEq(_state.stProtocolFee, _e.stProtocolFee, "returned ST protocol fee vs the independent recomputation");
        assertEq(_state.jtProtocolFee, _e.jtProtocolFee, "returned JT protocol fee vs the independent recomputation");
        assertEq(_state.lptProtocolFee, _e.lptProtocolFee, "returned LPT protocol fee vs the independent recomputation");
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(a.lastCollateralNAV, _e.collateralNAVNew, "committed collateral NAV must equal the measured input");
        assertEq(a.lastSTEffectiveNAV, _e.stEffectiveNAV, "committed ST effective NAV vs the independent recomputation");
        assertEq(a.lastJTEffectiveNAV, _e.jtEffectiveNAV, "committed JT effective NAV vs the independent recomputation");
        _assertCommittedConservation();

        // ── Independent counterweights (plain checked integers, no shared formula with the recomputation) ──
        // A sync only re-labels value between tranches: the liquidity premium and every fee are slices carved out
        // of what the collateral mark actually gained since the checkpoint, so none of them can exceed the measured
        // gross gain (each fee additionally bounded by its configured rate on that gain).
        uint256 grossGain =
            toUint256(_e.collateralNAVNew) > toUint256(_e.lastCollateralNAV) ? toUint256(_e.collateralNAVNew) - toUint256(_e.lastCollateralNAV) : 0;
        assertLe(toUint256(_state.lptLiquidityPremium), grossGain, "the liquidity premium cannot exceed the measured gross collateral gain");
        assertLe(toUint256(_state.stProtocolFee) * WAD, grossGain * _e.stProtocolFeeWAD, "the ST fee cannot exceed its rate on the measured gross gain");
        assertLe(
            toUint256(_state.jtProtocolFee) * WAD,
            grossGain * (uint256(_e.jtProtocolFeeWAD) + _e.jtYieldShareProtocolFeeWAD),
            "the JT fee cannot exceed its combined rates on the measured gross gain"
        );
        assertLe(
            toUint256(_state.lptProtocolFee) * WAD, grossGain * _e.lptYieldShareProtocolFeeWAD, "the LPT fee cannot exceed its rate on the measured gross gain"
        );
        // Monotonicity: when the collateral mark did not fall, attribution and the premium split can only move gain
        // between tranches, no tranche's effective NAV may fall on a no-loss sync.
        if (toUint256(_e.collateralNAVNew) >= toUint256(_e.lastCollateralNAV)) {
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
        _setupLPTProviders();
        uint256 collateralLegAssets = testConfig.initialFunding / 10_000;
        _seedLPTBalanced(LPT_ALICE_ADDRESS, collateralLegAssets);
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.8e18);
        _enableLPTOverlay(0.1e18, 0.5e18, minLiquidityWAD);
        vm.skip(!_trySetReinvestmentSlippage(0));
        _flushPremiumAccrual();
        _warpForward(1 days);
        _applySTYield(0.01e18);
        e = _buildSyncExpectation(false);
        assertGt(toUint256(e.lptLiquidityPremium), 0, "arrange: the LDM must price a nonzero liquidity premium");
    }

    /// @notice Stages an idle liquidity premium against the dust-deep pool (where the inline deployment cannot land)
    ///         and returns the staged idle senior share balance.
    function _arrangeStagedIdleLiquidityPremium() internal returns (uint256 idleShares) {
        _arrangeStagedPremiumSyncExpectation();
        _sync();
        idleShares = KERNEL.getState().lptOwnedSeniorTrancheShares;
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
        uint256 collateralLegAssets = testConfig.initialFunding / 100;
        _seedLPTBalanced(LPT_BOB_ADDRESS, collateralLegAssets);
        assertEq(KERNEL.getState().lptOwnedSeniorTrancheShares, idleShares, "arrange: deepening the pool must not consume the staged premium");
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
        assertEq(second.collateralNAV, first.collateralNAV, "the collateral NAV must not move");
        assertEq(second.lptRawNAV, first.lptRawNAV, "the liquidity raw NAV must not move");
        assertEq(second.stEffectiveNAV, first.stEffectiveNAV, "the senior effective NAV must not move");
        assertEq(second.jtEffectiveNAV, first.jtEffectiveNAV, "the junior effective NAV must not move");
        assertEq(second.jtImpermanentLoss, first.jtImpermanentLoss, "the impermanent loss must not move");
        assertEq(second.coverageUtilizationWAD, first.coverageUtilizationWAD, "the coverage utilization must not move");
        assertEq(second.liquidityUtilizationWAD, first.liquidityUtilizationWAD, "the liquidity utilization must not move");
        assertEq(second.lptLiquidityPremium, ZERO_NAV_UNITS, "the second sync must pay no liquidity premium");
        assertEq(second.stProtocolFee, ZERO_NAV_UNITS, "the second sync must take no ST fee");
        assertEq(second.jtProtocolFee, ZERO_NAV_UNITS, "the second sync must take no JT fee");
        assertEq(second.lptProtocolFee, ZERO_NAV_UNITS, "the second sync must take no LPT fee");

        assertEq(post.lastCollateralNAV, pre.lastCollateralNAV, "the committed collateral NAV must not move");
        assertEq(post.lastLPTRawNAV, pre.lastLPTRawNAV, "the committed LPT raw NAV must not move");
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV, "the committed ST effective NAV must not move");
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV, "the committed JT effective NAV must not move");
        assertEq(post.lastJTImpermanentLoss, pre.lastJTImpermanentLoss, "the committed impermanent loss must not move");
        assertEq(post.stSupply, pre.stSupply, "no senior shares may mint");
        assertEq(post.jtSupply, pre.jtSupply, "no junior shares may mint");
        assertEq(post.lptSupply, pre.lptSupply, "no liquidity shares may mint");
        assertEq(post.lptOwnedSeniorTrancheShares, pre.lptOwnedSeniorTrancheShares, "no premium may double-stage");
        assertEq(post.feeRecipientSTShares, pre.feeRecipientSTShares, "no ST fee may double-mint");
        assertEq(post.feeRecipientJTShares, pre.feeRecipientJTShares, "no JT fee may double-mint");
        assertEq(uint256(post.twJT), uint256(pre.twJT), "the JT accrual accumulator must not move");
        assertEq(uint256(post.twLPT), uint256(pre.twLPT), "the LPT accrual accumulator must not move");
        assertEq(uint256(post.lastAccrualTs), uint256(pre.lastAccrualTs), "the accrual timestamp must not move");
        assertEq(uint256(post.lastPremiumTs), uint256(pre.lastPremiumTs), "the premium timestamp must not move");
        _assertCommittedConservation();
    }

    /**
     * @notice A sync over a window with no collateral gain pays no premium, takes no fee, and mints nothing: it
     *         only settles the measured delta and books the window's time-weighted yield share accrual.
     * @dev A warp-only window is not guaranteed flat (a streaming underlying, like snUSD, drifts the collateral
     *      NAV up with time), so the measured drift is countered through the yield hook with a one-basis-point
     *      overshoot, pinning the window to the deterministic no-gain scenario. The residual small covered loss
     *      settles exactly per the independent recomputation with every fee and premium output zero.
     */
    function test_Sync_flat_noPnl_noFeesNoPremium() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        _warpForward(1 days);

        // Counter any streaming drift so the window nets to no collateral gain (a 0 percent move pins the rate)
        (NAV_UNIT collateralDrifted,) = _measureFreshSyncInputs(ZERO_TRANCHE_UNITS);
        NAV_UNIT lastCollateralNAV = ACCOUNTANT.getState().lastCollateralNAV;
        uint256 driftCounterPctWAD = collateralDrifted > lastCollateralNAV
            ? Math.mulDiv(toUint256(collateralDrifted - lastCollateralNAV), WAD, toUint256(collateralDrifted), Math.Rounding.Ceil) + 0.0001e18
            : 0;
        simulateSTLoss(driftCounterPctWAD);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertLe(e.collateralNAVNew, e.lastCollateralNAV, "arrange: the countered window must carry no collateral gain");
        assertGt(e.elapsed, 0, "arrange: the accrual window must be nonzero");
        assertEq(e.lptLiquidityPremium, ZERO_NAV_UNITS, "a no-gain window must pay no liquidity premium");
        assertEq(e.stProtocolFee, ZERO_NAV_UNITS, "a no-gain window must take no ST fee");
        assertEq(e.jtProtocolFee, ZERO_NAV_UNITS, "a no-gain window must take no JT fee");
        assertEq(e.lptProtocolFee, ZERO_NAV_UNITS, "a no-gain window must take no LPT fee");
        assertFalse(e.premiumsPaid, "a no-gain window must not pay premiums");
        MarketSnapshot memory pre = _snap();

        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertEq(state.lptLiquidityPremium, ZERO_NAV_UNITS, "the sync must pay no liquidity premium");
        assertEq(state.stProtocolFee, ZERO_NAV_UNITS, "the sync must take no ST fee");
        assertEq(state.jtProtocolFee, ZERO_NAV_UNITS, "the sync must take no JT fee");
        assertEq(state.lptProtocolFee, ZERO_NAV_UNITS, "the sync must take no LPT fee");
        assertEq(post.stSupply, pre.stSupply, "no senior shares may mint on a no-gain sync");
        assertEq(post.jtSupply, pre.jtSupply, "no junior shares may mint on a no-gain sync");
        assertEq(post.lptOwnedSeniorTrancheShares, pre.lptOwnedSeniorTrancheShares, "no premium may stage on a no-gain sync");
        assertEq(uint256(post.twJT), uint256(pre.twJT) + e.jtYieldShareWAD * e.elapsed, "the JT accrual must book exactly the window");
        assertEq(uint256(post.twLPT), uint256(pre.twLPT) + e.lptYieldShareWAD * e.elapsed, "the LPT accrual must book exactly the window");
        assertEq(uint256(post.lastAccrualTs), block.timestamp, "the accrual timestamp must re-stamp");
        assertEq(uint256(post.lastPremiumTs), uint256(pre.lastPremiumTs), "no premium payment may stamp without a paid premium");
    }

    // ── PnL sync scenarios: senior gain, covered loss, junior gain/loss, residual loss ──

    /**
     * @notice A senior-gain sync settles the full tranche accounting sync exactly: attribution, JT risk premium, both
     *         protocol fees, exact-args accrual and fee-mint events, and the post-payment accumulator reset.
     * @dev The one collateral rate moves the whole pool, so the expectation runs on the measured collateral
     *      delta. The name describes the hook intent, not a per-tranche delta shape.
     */
    function test_Sync_stGain_exactTrancheAccounting() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        _warpForward(1 days);
        _applySTYield(0.05e18);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(e.collateralNAVNew, e.lastCollateralNAV, "arrange: the collateral NAV must have appreciated");
        assertTrue(e.premiumsPaid, "arrange: the gain must clear the dust gate");
        assertGt(toUint256(e.stProtocolFee), 0, "arrange: an ST protocol fee must accrue");
        assertGt(toUint256(e.jtProtocolFee), 0, "arrange: a JT yield-share protocol fee must accrue");

        uint256 stSupplyPre = ST.totalSupply();
        uint256 jtSupplyPre = JT.totalSupply();
        (uint256 premShares, uint256 stFeeShares) =
            _expectedPremiumShares(e.lptLiquidityPremium, e.stProtocolFee, e.lptProtocolFee, e.stEffectiveNAV, stSupplyPre);
        uint256 jtFeeShares = _expectedShares(e.jtProtocolFee, jtSupplyPre, e.jtEffectiveNAV - e.jtProtocolFee);
        MarketSnapshot memory pre = _snap();

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.YieldSharesAccrued(
            e.jtYieldShareWAD, e.twJTStart + e.jtYieldShareWAD * e.elapsed, e.lptYieldShareWAD, e.twLPTStart + e.lptYieldShareWAD * e.elapsed
        );
        vm.expectEmit(true, false, false, true, address(ST));
        emit IRoycoVaultTranche.ProtocolFeeSharesMinted(PROTOCOL_FEE_RECIPIENT_ADDRESS, stFeeShares, stSupplyPre + premShares + stFeeShares);
        vm.expectEmit(true, false, false, true, address(JT));
        emit IRoycoVaultTranche.ProtocolFeeSharesMinted(PROTOCOL_FEE_RECIPIENT_ADDRESS, jtFeeShares, jtSupplyPre + jtFeeShares);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertEq(post.lastJTImpermanentLoss, e.jtImpermanentLoss, "committed impermanent loss must match the independent recomputation");
        assertEq(post.stSupply, pre.stSupply + premShares + stFeeShares, "ST supply must grow by exactly the premium and fee mints");
        assertEq(post.jtSupply, pre.jtSupply + jtFeeShares, "JT supply must grow by exactly the fee mint");
        assertEq(post.feeRecipientSTShares - pre.feeRecipientSTShares, stFeeShares, "ST fee shares minted to the recipient");
        assertEq(post.feeRecipientJTShares - pre.feeRecipientJTShares, jtFeeShares, "JT fee shares minted to the recipient");
        assertEq(uint256(post.lastPremiumTs), block.timestamp, "the premium payment must stamp");
        assertEq(uint256(post.twJT), 0, "the JT accrual accumulator must reset after payment");
        assertEq(uint256(post.twLPT), 0, "the LPT accrual accumulator must reset after payment");
        // Counterweight independent of the share-pricing mirror: the premium/fee mints pay for value already booked
        // into the senior effective NAV, so the pre-existing holders' NAV-per-share cannot fall across the sync.
        _assertSeniorMintsNonDilutive(stSupplyPre, e.lptLiquidityPremium + e.stProtocolFee);
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
        assertLt(e.collateralNAVNew, e.lastCollateralNAV, "arrange: the collateral NAV must have depreciated");
        assertGt(toUint256(e.jtImpermanentLoss), 0, "arrange: coverage must be applied");
        assertGt(toUint256(e.jtEffectiveNAV), 0, "arrange: the loss must not exhaust the junior tranche");
        assertEq(e.stEffectiveNAV, e.lastSTEffectiveNAV, "the covered loss must leave the senior effective NAV whole");

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(e.jtImpermanentLoss);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertTrue(a.lastMarketState == MarketState.PERPETUAL, "the market must stay perpetual");
        assertEq(a.lastJTImpermanentLoss, ZERO_NAV_UNITS, "the forced perpetual transition must erase the impermanent loss");
        assertEq(state.jtImpermanentLoss, ZERO_NAV_UNITS, "the returned packet must carry the erased impermanent loss");
        assertEq(state.stProtocolFee, ZERO_NAV_UNITS, "a loss sync must take no ST fee");
        assertEq(state.jtProtocolFee, ZERO_NAV_UNITS, "a loss sync must take no JT fee");
    }

    /**
     * @notice A covered loss on a nonzero-duration market commences a fixed term: exact end timestamp and
     *         event, exact retained impermanent loss, every fee and the LPT premium zeroed, the accrued
     *         yield-share window retained (not reset), and the deposit lockout active.
     */
    function test_Sync_stLoss_entersFixedTerm_feesAndLPTPremiumZeroed() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _setupLPTProviders();
        uint256 collateralLegAssets = testConfig.initialFunding / 100;
        _seedLPTBalanced(LPT_ALICE_ADDRESS, collateralLegAssets);
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.8e18);
        _enableLPTOverlay(0.1e18, 0.5e18, minLiquidityWAD);
        _setFixedTermDuration(7 days);
        _flushPremiumAccrual();
        uint256 premiumTsPre = ACCOUNTANT.getState().lastPremiumPaymentTimestamp;
        _warpForward(1 days);
        _applySTLoss(0.02e18);

        SyncExpectation memory e = _buildSyncExpectation(true);
        assertGt(e.jtImpermanentLoss, e.dustTolerance, "arrange: the coverage applied must exceed the dust tolerance");
        assertGt(toUint256(e.jtEffectiveNAV), 0, "arrange: the loss must not exhaust the junior tranche");
        assertGt(e.lptYieldShareWAD, 0, "arrange: a liquidity premium must have been accruing");
        uint32 expectedEndTimestamp = uint32(block.timestamp + 7 days);

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.FixedTermCommenced(expectedEndTimestamp);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        assertTrue(state.marketState == MarketState.FIXED_TERM, "the returned packet must carry the fixed-term state");
        assertEq(state.lptLiquidityPremium, ZERO_NAV_UNITS, "the fixed-term sync must pay no liquidity premium");
        assertEq(state.stProtocolFee, ZERO_NAV_UNITS, "the fixed-term sync must take no ST fee");
        assertEq(state.jtProtocolFee, ZERO_NAV_UNITS, "the fixed-term sync must take no JT fee");
        assertEq(state.lptProtocolFee, ZERO_NAV_UNITS, "the fixed-term sync must take no LPT fee");
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertTrue(a.lastMarketState == MarketState.FIXED_TERM, "the market must enter the fixed term");
        assertEq(uint256(a.fixedTermEndTimestamp), uint256(expectedEndTimestamp), "the fixed-term end must stamp exactly");
        assertEq(a.lastJTImpermanentLoss, e.jtImpermanentLoss, "the impermanent loss must be retained exactly");
        assertEq(uint256(a.twJTYieldShareAccruedWAD), e.twJTStart + e.jtYieldShareWAD * e.elapsed, "the unpaid JT accrual must be retained");
        assertEq(uint256(a.twLPTYieldShareAccruedWAD), e.twLPTStart + e.lptYieldShareWAD * e.elapsed, "the unpaid LPT accrual must be retained");
        assertEq(uint256(a.lastPremiumPaymentTimestamp), premiumTsPre, "no premium payment may stamp on a loss sync");

        uint256 assets = testConfig.initialFunding / 100;
        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(ST), assets);
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
        assertGt(a0.lastJTImpermanentLoss, ZERO_NAV_UNITS, "arrange: an impermanent loss must be retained");

        _warpForward(1 days);
        _applySTYield(0.05e18);
        SyncExpectation memory e = _buildSyncExpectation(false);
        assertEq(e.jtImpermanentLoss, ZERO_NAV_UNITS, "arrange: the gain must fully recover the impermanent loss");
        assertTrue(e.premiumsPaid, "arrange: a residual gain must remain after the recovery");
        assertGt(toUint256(e.stProtocolFee), 0, "arrange: the exited market must take fees again");

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.FixedTermEnded();
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertTrue(a.lastMarketState == MarketState.PERPETUAL, "the market must exit the fixed term");
        assertEq(a.lastJTImpermanentLoss, ZERO_NAV_UNITS, "the impermanent loss must be fully recovered");
        assertEq(uint256(a.fixedTermEndTimestamp), 0, "the fixed-term end must clear");
        assertEq(uint256(a.lastPremiumPaymentTimestamp), block.timestamp, "the premium payment must stamp");
        assertEq(uint256(a.twJTYieldShareAccruedWAD), 0, "the JT accrual accumulator must reset after payment");
        assertEq(uint256(a.twLPTYieldShareAccruedWAD), 0, "the LPT accrual accumulator must reset after payment");
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
        NAV_UNIT ilBefore = a0.lastJTImpermanentLoss;
        assertGt(ilBefore, ZERO_NAV_UNITS, "arrange: an impermanent loss must be retained");

        _warpForward(uint256(a0.fixedTermDurationSeconds) + 1);
        assertGt(block.timestamp, uint256(a0.fixedTermEndTimestamp), "arrange: the fixed term must have elapsed");
        uint256 premiumTsPre = a0.lastPremiumPaymentTimestamp;

        // The elapsed window may carry streaming drift, so the settlement runs on the measured deltas
        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(toUint256(e.jtImpermanentLoss), 0, "arrange: an unrecovered impermanent loss must remain to erase");
        assertLe(e.jtImpermanentLoss, ilBefore, "arrange: recovery can only shrink the retained impermanent loss");

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(e.jtImpermanentLoss);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertTrue(state.marketState == MarketState.PERPETUAL, "the market must be forced perpetual");
        assertEq(post.lastJTImpermanentLoss, ZERO_NAV_UNITS, "the unrecovered impermanent loss must be erased");
        assertEq(state.jtImpermanentLoss, ZERO_NAV_UNITS, "the returned packet must carry the erased impermanent loss");
        assertEq(uint256(post.fixedTermEnd), 0, "the fixed-term end must clear");
        assertEq(uint256(post.lastPremiumTs), e.premiumsPaid ? block.timestamp : premiumTsPre, "the premium stamp must track the payment");
        assertEq(uint256(post.twJT), e.premiumsPaid ? 0 : e.twJTStart + e.jtYieldShareWAD * e.elapsed, "the accumulator must reset only on payment");
    }

    /**
     * @notice A junior-gain sync settles the full tranche accounting sync exactly against the measured delta.
     * @dev The one collateral rate moves both tranches together, so the JT yield hook drives the same
     *      collateral-gain pipeline as the senior hook and completes the reachable delta scenarios
     *      alongside the flat, senior-gain, and loss syncs.
     */
    function test_Sync_jtGain_exactTrancheAccounting() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        uint256 premiumTsPre = ACCOUNTANT.getState().lastPremiumPaymentTimestamp;
        _warpForward(1 days);
        _applyJTYield(0.05e18);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(e.collateralNAVNew, e.lastCollateralNAV, "arrange: the collateral NAV must have appreciated");

        uint256 stSupplyPre = ST.totalSupply();
        uint256 jtSupplyPre = JT.totalSupply();
        (uint256 premShares, uint256 stFeeShares) =
            _expectedPremiumShares(e.lptLiquidityPremium, e.stProtocolFee, e.lptProtocolFee, e.stEffectiveNAV, stSupplyPre);
        uint256 jtFeeShares = _expectedShares(e.jtProtocolFee, jtSupplyPre, e.jtEffectiveNAV - e.jtProtocolFee);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertEq(post.lastJTImpermanentLoss, e.jtImpermanentLoss, "committed impermanent loss must match the independent recomputation");
        assertEq(post.stSupply, stSupplyPre + premShares + stFeeShares, "ST supply must grow by exactly the premium and fee mints");
        assertEq(post.jtSupply, jtSupplyPre + jtFeeShares, "JT supply must grow by exactly the fee mint");
        assertEq(uint256(post.lastPremiumTs), e.premiumsPaid ? block.timestamp : premiumTsPre, "the premium stamp must track the payment");
        assertEq(uint256(post.twJT), e.premiumsPaid ? 0 : e.twJTStart + e.jtYieldShareWAD * e.elapsed, "the accumulator must reset only on payment");
        // Counterweight independent of the share-pricing mirror: any premium/fee mint this sync produced pays for
        // value already booked into the senior effective NAV, so pre-existing holders cannot be diluted.
        _assertSeniorMintsNonDilutive(stSupplyPre, e.lptLiquidityPremium + e.stProtocolFee);
        _assertCommittedConservation();
    }

    /**
     * @notice A junior-loss sync settles the coverage path of the sync exactly against the measured delta, with
     *         the forced-perpetual erase on the zero-duration baseline.
     * @dev The one collateral rate couples the tranches, so the JT loss hook depreciates the whole pool: the
     *      JT-attributed residual books IL directly and the ST-attributed leg applies coverage on top, so a
     *      nonzero IL always books and the erase event always fires. A JT-only loss is unrepresentable.
     */
    function test_Sync_jtLoss_exactTrancheAccounting() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        // Establish the zero-duration (permanently perpetual) regime rather than requiring it of the deployed config
        if (uint256(ACCOUNTANT.getState().fixedTermDurationSeconds) != 0) _setFixedTermDuration(0);

        _applyJTLoss(0.02e18);
        SyncExpectation memory e = _buildSyncExpectation(false);
        assertLt(e.collateralNAVNew, e.lastCollateralNAV, "arrange: the collateral NAV must have depreciated");
        assertLt(e.jtEffectiveNAV, e.lastJTEffectiveNAV, "the junior effective NAV must absorb the loss");
        assertGt(toUint256(e.jtImpermanentLoss), 0, "the coupled loss must book an impermanent loss");
        assertEq(e.stEffectiveNAV, e.lastSTEffectiveNAV, "coverage must leave the senior effective NAV whole");

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(e.jtImpermanentLoss);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertTrue(a.lastMarketState == MarketState.PERPETUAL, "the market must stay perpetual");
        assertEq(a.lastJTImpermanentLoss, ZERO_NAV_UNITS, "the forced perpetual transition must erase the impermanent loss");
        assertEq(state.stProtocolFee, ZERO_NAV_UNITS, "a loss sync must take no ST fee");
        assertEq(state.jtProtocolFee, ZERO_NAV_UNITS, "a loss sync must take no JT fee");
        assertEq(state.lptLiquidityPremium, ZERO_NAV_UNITS, "a loss sync must pay no liquidity premium");
    }

    /**
     * @notice A loss exceeding the junior loss-absorption buffer settles the residual-loss path of the sync exactly: coverage
     *         exhausts the junior effective NAV to exactly zero, the residual falls on the senior effective NAV,
     *         coverage utilization saturates, and the exhausted market is forced perpetual with the IL erased.
     */
    function test_Sync_stLoss_residualExceedsCoverage_exactTrancheAccounting() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 16);
        _sync();

        // Size the loss from the measured committed ratio so it strictly exceeds the junior buffer: a rate
        // loss of fraction p removes about p of each tranche's attributed slice, so JT exhausts once
        // p * stEff >= (1 - p) * jtEff, that is p >= jtEff / collateralNAV, padded 2 percent
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        uint256 lossPctWAD = Math.mulDiv(toUint256(a0.lastJTEffectiveNAV), WAD, toUint256(a0.lastCollateralNAV), Math.Rounding.Ceil) + 0.02e18;
        assertLt(lossPctWAD, WAD, "arrange: the exhausting loss must be representable");
        _applySTLoss(lossPctWAD);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertLt(e.collateralNAVNew, e.lastCollateralNAV, "arrange: the collateral NAV must have depreciated");
        assertEq(e.jtEffectiveNAV, ZERO_NAV_UNITS, "the coverage application must exhaust the junior effective NAV to exactly zero");
        assertLt(e.stEffectiveNAV, e.lastSTEffectiveNAV, "the residual loss must fall on the senior effective NAV");
        assertGt(toUint256(e.jtImpermanentLoss), 0, "arrange: the applied coverage must book an impermanent loss");

        // The exhausted (jtEffectiveNAV == 0, stEffectiveNAV > 0) market is forced perpetual, erasing the just-booked IL
        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(e.jtImpermanentLoss);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        assertEq(state.coverageUtilizationWAD, type(uint256).max, "coverage utilization must saturate with an exhausted junior tranche");
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertTrue(a.lastMarketState == MarketState.PERPETUAL, "the exhausted market must be forced perpetual");
        assertEq(a.lastJTImpermanentLoss, ZERO_NAV_UNITS, "the forced perpetual transition must erase the impermanent loss");
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

        assertEq(state.lptLiquidityPremium, ZERO_NAV_UNITS, "the genesis sync must pay no liquidity premium");
        assertEq(state.stProtocolFee, ZERO_NAV_UNITS, "the genesis sync must take no ST fee");
        assertEq(state.jtProtocolFee, ZERO_NAV_UNITS, "the genesis sync must take no JT fee");
        assertEq(state.stEffectiveNAV, ZERO_NAV_UNITS, "no senior value exists before the first deposit");
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(uint256(a.lastYieldShareAccrualTimestamp), block.timestamp, "the accrual clock must initialize");
        assertEq(uint256(a.lastPremiumPaymentTimestamp), block.timestamp, "the premium clock must initialize");
        assertEq(uint256(a.twJTYieldShareAccruedWAD), 0, "no pre-genesis JT accrual may book");
        assertEq(uint256(a.twLPTYieldShareAccruedWAD), 0, "no pre-genesis LPT accrual may book");
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
            e.jtYieldShareWAD, e.twJTStart + e.jtYieldShareWAD * e.elapsed, e.lptYieldShareWAD, e.twLPTStart + e.lptYieldShareWAD * e.elapsed
        );
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(uint256(a.lastPremiumPaymentTimestamp), block.timestamp, "the premium payment must stamp");
        assertEq(uint256(a.twJTYieldShareAccruedWAD), 0, "the JT accrual accumulator must reset after payment");
        assertEq(uint256(a.twLPTYieldShareAccruedWAD), 0, "the LPT accrual accumulator must reset after payment");
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

        // Window 1: warp, counter the streaming drift so no collateral gain books, and sync (accrues, pays nothing)
        _warpForward(1 days);
        (NAV_UNIT collateralDrifted,) = _measureFreshSyncInputs(ZERO_TRANCHE_UNITS);
        NAV_UNIT lastCollateralNAV = ACCOUNTANT.getState().lastCollateralNAV;
        uint256 driftCounterPctWAD = collateralDrifted > lastCollateralNAV
            ? Math.mulDiv(toUint256(collateralDrifted - lastCollateralNAV), WAD, toUint256(collateralDrifted), Math.Rounding.Ceil) + 0.0001e18
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
        assertEq(uint256(a.twLPTYieldShareAccruedWAD), 0, "the LPT accrual accumulator must reset after payment");
    }

    // ── The LPT liquidity premium mint ──

    /// @notice The LPT liquidity premium mints exactly the expected senior shares into the kernel's idle
    ///         ledger, with exact-args accrual and premium-mint events and the joint-pricing supply growth.
    function test_Sync_lptLiquidityPremium_mintsIdleSTShares() public whenLPT {
        SyncExpectation memory e = _arrangeStagedPremiumSyncExpectation();
        assertLe(e.jtYieldShareWAD + e.lptYieldShareWAD, WAD, "the yield share caps must preclude PREMIUMS_EXCEED_SENIOR_YIELD");
        uint256 stSupplyPre = ST.totalSupply();
        (uint256 premShares, uint256 stFeeShares) =
            _expectedPremiumShares(e.lptLiquidityPremium, e.stProtocolFee, e.lptProtocolFee, e.stEffectiveNAV, stSupplyPre);
        assertGt(premShares, 0, "arrange: the premium must mint shares");
        MarketSnapshot memory pre = _snap();

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.YieldSharesAccrued(
            e.jtYieldShareWAD, e.twJTStart + e.jtYieldShareWAD * e.elapsed, e.lptYieldShareWAD, e.twLPTStart + e.lptYieldShareWAD * e.elapsed
        );
        // The ST protocol fee mint lands first, so the premium mint's post-mint supply carries the fee shares too
        vm.expectEmit(true, false, false, true, address(ST));
        emit IRoycoSeniorTranche.LiquidityPremiumSharesMinted(address(KERNEL), premShares, stSupplyPre + stFeeShares + premShares);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertEq(post.lptOwnedSeniorTrancheShares, pre.lptOwnedSeniorTrancheShares + premShares, "the premium must stage as idle senior shares");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal + premShares, "the kernel must custody the minted premium shares");
        assertEq(post.stSupply, pre.stSupply + premShares + stFeeShares, "senior supply must grow by exactly the premium and fee share mints");
        // Counterweight independent of the share-pricing mirror: the staged premium shares are floor-priced against
        // the retained senior NAV, so plain senior holders' NAV-per-share cannot fall when the premium mints.
        _assertSeniorMintsNonDilutive(stSupplyPre, e.lptLiquidityPremium + e.stProtocolFee);
        _assertSolvency();
    }

    /**
     * @notice The premium mint is coverage-neutral: it moves no collateral NAV, grows senior supply by exactly the
     *         premium and fee share mints, keeps the premium inside the senior effective NAV, and leaves the production
     *         coverage utilization equal to the independent recompute.
     */
    function test_Sync_premiumMint_coverageNeutral() public whenLPT {
        SyncExpectation memory e = _arrangeStagedPremiumSyncExpectation();
        uint256 stSupplyPre = ST.totalSupply();
        (uint256 premShares, uint256 stFeeShares) =
            _expectedPremiumShares(e.lptLiquidityPremium, e.stProtocolFee, e.lptProtocolFee, e.stEffectiveNAV, stSupplyPre);
        assertGt(premShares, 0, "arrange: the premium must mint shares");

        SyncedAccountingState memory state = _syncWithState();

        MarketSnapshot memory post = _snap();
        assertEq(post.lastCollateralNAV, e.collateralNAVNew, "the mint must move no collateral NAV");
        assertEq(post.stSupply, stSupplyPre + premShares + stFeeShares, "senior supply must grow by exactly the premium and fee shares");
        assertEq(post.lastSTEffectiveNAV, e.stEffectiveNAV, "the senior effective NAV must include the minted premium");
        assertEq(
            state.coverageUtilizationWAD,
            _expectedCoverageUtilization(e.collateralNAVNew, ACCOUNTANT.getState().minCoverageWAD, e.jtEffectiveNAV),
            "the production coverage utilization must match the independent recompute"
        );
        // Counterweight independent of the share-pricing mirror: the coverage-neutral mint reassigns senior
        // appreciation without diluting the pre-existing holders' NAV-per-share.
        _assertSeniorMintsNonDilutive(stSupplyPre, e.lptLiquidityPremium + e.stProtocolFee);
        _assertCommittedConservation();
    }

    /// @notice The committed LPT raw NAV marks the BPT only while the LPT effective NAV adds the claimable idle
    ///         premium leg, and the liquidity utilization reads the BPT-only mark.
    function test_Sync_lptRawNAVExcludesIdle_effectiveIncludesIt() public whenLPT {
        uint256 idleShares = _arrangeLPTWithStagedIdleLiquidityPremium();

        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(a.lastLPTRawNAV, KERNEL.convertLPTAssetsToValue(KERNEL.getState().totalLPTAssets), "the committed LPT raw NAV must be the BPT mark only");
        NAV_UNIT idleValue = _expectedValue(idleShares, ST.totalSupply(), a.lastSTEffectiveNAV);
        assertGt(toUint256(idleValue), 0, "arrange: the staged premium must carry value");
        assertApproxEqAbs(LPT.totalAssets().nav, a.lastLPTRawNAV + idleValue, maxNAVDelta(), "the LPT effective NAV must include the claimable idle leg");

        // The split valuation surfaces on the real stack: the external convert* exchange rate is BPT-only (raw NAV,
        // no idle senior-share leg), while totalAssets (above) and previewRedeem keep the claimable idle leg, so
        // the convert quote sits strictly below the redemption quote for the same shares while premium is staged.
        // previewRedeem simulates the real redemption, so the probe is sized to clear the post-op liquidity gate
        // (a tenth of the supply leaves utilization near 0.8 / 0.9 against the ~80 percent arranged target)
        uint256 probeShares = LPT.totalSupply() / 10;
        AssetClaims memory convClaims = LPT.convertToAssets(probeShares);
        assertEq(convClaims.stShares, 0, "convertToAssets must report no senior-share claim (the idle leg is excluded)");
        assertApproxEqAbs(
            convClaims.nav,
            _expectedValue(probeShares, LPT.totalSupply(), a.lastLPTRawNAV),
            maxNAVDelta(),
            "convertToAssets must price the pro-rata slice of the BPT-only raw NAV"
        );
        assertGt(
            toUint256(LPT.previewRedeem(probeShares).nav),
            toUint256(convClaims.nav),
            "the redemption quote must sit strictly above the BPT-only convert quote while premium is staged"
        );

        SyncedAccountingState memory state = _syncWithState();
        uint256 rawBasedUtilWAD = _expectedLiquidityUtilization(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLPTRawNAV);
        assertEq(state.liquidityUtilizationWAD, rawBasedUtilWAD, "the production liquidity utilization must match the BPT-only recompute exactly");
        assertGt(
            rawBasedUtilWAD,
            _expectedLiquidityUtilization(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLPTRawNAV + idleValue),
            "the BPT-only utilization must read strictly under-provisioned versus the effective NAV while premium is staged"
        );
    }

    // ── The premium reinvestment (inline and on demand) ──

    /**
     * @notice The production steady state: with the slippage gate open against a deep pool, a plain sync mints
     *         the liquidity premium AND deploys it inline in the same sync, nothing stages, the owned depth
     *         grows by the reported venue mint clearing the gate's derived minimum, and the freshly deployed
     *         depth is re-committed.
     */
    function test_Sync_lptPremium_inlineReinvestment_deploysSameSync() public whenLPT {
        uint64 slippageWAD = 0.5e18;
        vm.skip(!_trySetReinvestmentSlippage(slippageWAD));
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
        _sync();
        _enableLPTOverlay(0.1e18, 0.5e18, _minLiquidityForTargetUtilization(0.8e18));
        _flushPremiumAccrual();
        _warpForward(1 days);
        _applySTYield(0.02e18);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(toUint256(e.lptLiquidityPremium), 0, "arrange: the LDM must price a nonzero liquidity premium");
        uint256 stSupplyPre = ST.totalSupply();
        (uint256 premShares, uint256 stFeeShares) =
            _expectedPremiumShares(e.lptLiquidityPremium, e.stProtocolFee, e.lptProtocolFee, e.stEffectiveNAV, stSupplyPre);
        assertGt(premShares, 0, "arrange: the premium must mint shares");
        NAV_UNIT premiumValue = _expectedValue(premShares, stSupplyPre + premShares + stFeeShares, e.stEffectiveNAV);
        uint256 minLptAssetsOut = Math.mulDiv(toUint256(KERNEL.convertValueToLPTAssets(premiumValue)), WAD - slippageWAD, WAD, Math.Rounding.Ceil);
        assertGt(minLptAssetsOut, 0, "arrange: the gate minimum must be nonzero");
        MarketSnapshot memory pre = _snap();
        assertEq(pre.lptOwnedSeniorTrancheShares, 0, "arrange: nothing may be staged before the sync");

        vm.recordLogs();
        SyncedAccountingState memory state = _syncWithState();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertEq(post.lptOwnedSeniorTrancheShares, 0, "the premium must deploy inline, staging nothing");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal, "the kernel must hold no residual senior shares");
        assertEq(post.stSupply, pre.stSupply + premShares + stFeeShares, "senior supply must grow by exactly the premium and fee share mints");

        (uint256 reinvestedCount, bytes memory reinvestedData) = _lastLogData(logs, address(KERNEL), IRoycoDayKernel.LiquidityPremiumReinvested.selector);
        assertEq(reinvestedCount, 1, "exactly one inline reinvestment must be reported");
        (uint256 stSharesReinvested, uint256 lptAssetsMinted) = abi.decode(reinvestedData, (uint256, uint256));
        assertEq(stSharesReinvested, premShares, "the entire minted premium must deploy");
        uint256 ownedDeltaAssets = toUint256(post.lptOwned - pre.lptOwned);
        assertEq(lptAssetsMinted, ownedDeltaAssets, "the reported venue mint must match the owned-ledger delta");
        assertEq(post.kernelBPTBal - pre.kernelBPTBal, ownedDeltaAssets, "the kernel's BPT balance must grow by exactly the venue mint");
        assertGe(ownedDeltaAssets, minLptAssetsOut, "the inline mint must clear the slippage gate's derived minimum");
        assertEq(post.lastLPTRawNAV, KERNEL.convertLPTAssetsToValue(post.lptOwned), "the freshly deployed depth must be re-committed");
        assertGt(post.lastLPTRawNAV, pre.lastLPTRawNAV, "the committed depth must grow");
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
    function test_ReinvestLiquidityPremium_movesIdleIntoBPT() public whenLPT {
        uint256 idleShares = _arrangeReinvestableIdleLiquidityPremium();
        uint64 slippageWAD = 0.5e18;
        assertTrue(_trySetReinvestmentSlippage(slippageWAD), "arrange: the slippage gate must open");

        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        NAV_UNIT idleValue = _expectedValue(idleShares, ST.totalSupply(), a.lastSTEffectiveNAV);
        uint256 minLptAssetsOut = Math.mulDiv(toUint256(KERNEL.convertValueToLPTAssets(idleValue)), WAD - slippageWAD, WAD, Math.Rounding.Ceil);
        assertGt(minLptAssetsOut, 0, "arrange: the gate minimum must be nonzero");
        MarketSnapshot memory pre = _snap();

        vm.recordLogs();
        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(type(uint256).max);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        MarketSnapshot memory post = _snap();
        assertEq(post.lptOwnedSeniorTrancheShares, 0, "the entire idle balance must deploy");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal - idleShares, "the kernel must release the reinvested shares to the venue");
        assertEq(post.stSupply, pre.stSupply, "a reinvestment mints and burns no senior shares");
        uint256 ownedDeltaAssets = toUint256(post.lptOwned - pre.lptOwned);
        assertGe(ownedDeltaAssets, minLptAssetsOut, "the venue mint must clear the slippage gate's derived minimum");

        (uint256 reinvestedCount, bytes memory reinvestedData) = _lastLogData(logs, address(KERNEL), IRoycoDayKernel.LiquidityPremiumReinvested.selector);
        assertEq(reinvestedCount, 1, "exactly one reinvestment must be reported");
        (uint256 stSharesReinvested, uint256 lptAssetsMinted) = abi.decode(reinvestedData, (uint256, uint256));
        assertEq(stSharesReinvested, idleShares, "the event must report the exact idle balance deployed");
        assertEq(lptAssetsMinted, ownedDeltaAssets, "the event's venue mint must match the owned-ledger delta exactly");
        // The independent signal: the kernel's ERC20 BPT balance grew by exactly the credited mint
        assertEq(post.kernelBPTBal - pre.kernelBPTBal, ownedDeltaAssets, "the kernel's BPT balance must grow by exactly the credited venue mint");

        (uint256 commitCount, bytes memory commitData) =
            _lastLogData(logs, address(ACCOUNTANT), IRoycoDayAccountant.LiquidityProviderTrancheRawNAVCommitted.selector);
        assertGt(commitCount, 0, "the fresh depth must be re-committed");
        assertEq(toNAVUnits(abi.decode(commitData, (uint256))), post.lastLPTRawNAV, "the final commit must carry the committed mark");
        assertGt(post.lastLPTRawNAV, pre.lastLPTRawNAV, "the committed depth must grow");
        assertLt(post.liquidityUtilizationWAD, pre.liquidityUtilizationWAD, "the deployment must lower liquidity utilization");
        _assertSolvency();
        _assertCommittedConservation();
    }

    /// @notice A partial reinvestment debits exactly the requested shares from the idle ledger, leaves the
    ///         remainder staged, and its venue mint clears the slippage gate's derived minimum.
    function test_ReinvestLiquidityPremium_partialAmount() public whenLPT {
        uint256 idleShares = _arrangeReinvestableIdleLiquidityPremium();
        uint64 slippageWAD = 0.5e18;
        assertTrue(_trySetReinvestmentSlippage(slippageWAD), "arrange: the slippage gate must open");
        uint256 partialShares = idleShares / 2;
        assertGt(partialShares, 0, "arrange: the partial amount must be nonzero");

        // The same min-out derivation as the full-amount test, applied to the partial share count
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        NAV_UNIT partialValue = _expectedValue(partialShares, ST.totalSupply(), a.lastSTEffectiveNAV);
        uint256 minLptAssetsOut = Math.mulDiv(toUint256(KERNEL.convertValueToLPTAssets(partialValue)), WAD - slippageWAD, WAD, Math.Rounding.Ceil);
        assertGt(minLptAssetsOut, 0, "arrange: the gate minimum must be nonzero");
        MarketSnapshot memory pre = _snap();

        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(partialShares);

        MarketSnapshot memory post = _snap();
        assertEq(post.lptOwnedSeniorTrancheShares, idleShares - partialShares, "exactly the requested shares must leave the idle ledger");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal - partialShares, "the kernel must release exactly the requested shares");
        assertGe(toUint256(post.lptOwned - pre.lptOwned), minLptAssetsOut, "the venue mint must clear the slippage gate's derived minimum");
        assertEq(
            post.kernelBPTBal - pre.kernelBPTBal, toUint256(post.lptOwned - pre.lptOwned), "the kernel's BPT balance must grow by exactly the credited mint"
        );
        _assertSolvency();
        _assertCommittedConservation();
    }

    /**
     * @notice A reinvestment attempt whose venue add cannot land is tolerated, not reverted: the idle and
     *         owned ledgers are untouched, no reinvestment event fires, and the market is unchanged.
     * @dev The staged premium overruns the dust pool's venue bounds and the slippage gate is forced shut,
     *      so the inner add reverts and the failure must be swallowed gracefully.
     */
    function test_ReinvestLiquidityPremium_gateFailureTolerated() public whenLPT {
        uint256 idleShares = _arrangeStagedIdleLiquidityPremium();
        MarketSnapshot memory pre = _snap();

        vm.recordLogs();
        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(type(uint256).max);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 reinvestedCount,) = _lastLogData(logs, address(KERNEL), IRoycoDayKernel.LiquidityPremiumReinvested.selector);
        assertEq(reinvestedCount, 0, "no reinvestment event may fire against a shut gate");
        assertEq(KERNEL.getState().lptOwnedSeniorTrancheShares, idleShares, "the idle ledger must be untouched");
        _assertMarketUnchanged(pre);
        _assertSolvency();
    }

    /**
     * @notice The full premium lifecycle: a staged tranche of premium is partially claimed in kind by a
     *         redeemer, the remainder deploys once the gate opens, and every minted premium share is
     *         accounted for as paid out, reinvested, or still idle (a ghost-ledger identity).
     */
    function test_LPTPremium_lifecycle_endToEnd() public whenLPT {
        uint256 idleStaged = _arrangeReinvestableIdleLiquidityPremium();

        // Step 1: a redeemer takes 25 percent in kind and is paid its idle liquidity premium slice directly
        uint256 lptSupply = LPT.totalSupply();
        uint256 shares = LPT.balanceOf(LPT_BOB_ADDRESS) / 4;
        // The idle-premium share slice scales through _scaleAssetClaims, dividing by the effective supply (+ 1e6)
        uint256 expectedIdleSlice = Math.mulDiv(idleStaged, shares, lptSupply + VIRTUAL_SHARES);
        assertGt(expectedIdleSlice, 0, "arrange: the redemption must claim an idle liquidity premium slice");
        uint256 redeemerSTSharesPre = ST.balanceOf(LPT_BOB_ADDRESS);
        OpReceipt memory r = _doRedeemLPT(LPT_BOB_ADDRESS, shares);
        assertEq(ST.balanceOf(LPT_BOB_ADDRESS) - redeemerSTSharesPre, expectedIdleSlice, "the idle liquidity premium slice must be paid directly");
        assertEq(r.post.lptOwnedSeniorTrancheShares, idleStaged - expectedIdleSlice, "the idle ledger must fall by the paid slice");
        assertGt(toUint256(r.claims.lptAssets), 0, "the redemption must pay a BPT slice");
        assertLe(r.post.liquidityUtilizationWAD, WAD, "the redemption must leave the liquidity requirement satisfied");
        _assertCommittedConservation();

        // Step 2: the gate opens and the remaining staged premium deploys into real depth
        assertTrue(_trySetReinvestmentSlippage(0.5e18), "arrange: the slippage gate must open");
        MarketSnapshot memory preReinvest = _snap();
        uint256 reinvestedShares = preReinvest.lptOwnedSeniorTrancheShares;
        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(type(uint256).max);
        MarketSnapshot memory post = _snap();
        assertEq(post.lptOwnedSeniorTrancheShares, 0, "the remaining staged premium must deploy");
        assertGt(post.lptOwned, preReinvest.lptOwned, "the deployment must credit the owned ledger");
        assertGt(post.lastLPTRawNAV, preReinvest.lastLPTRawNAV, "the committed depth must grow");
        assertLt(post.liquidityUtilizationWAD, preReinvest.liquidityUtilizationWAD, "the deployment must lower liquidity utilization");

        // Ghost ledger: every minted premium share is paid out, reinvested, or still idle
        assertEq(
            idleStaged, expectedIdleSlice + reinvestedShares + post.lptOwnedSeniorTrancheShares, "ghost: minted premium shares must be fully accounted for"
        );
        _assertSolvency();
        _assertCommittedConservation();
    }

    // ── The yield share caps ──

    /// @notice When the YDM curves price above the configured maximums, the accrued yield shares bind at the
    ///         caps exactly, pinned by the exact-args accrual events and the capped premium settlement.
    function test_Sync_maxYieldSharesCapBinds() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 16);
        _setupLPTProviders();
        uint256 collateralLegAssets = testConfig.initialFunding / 100;
        _seedLPTBalanced(LPT_ALICE_ADDRESS, collateralLegAssets);
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.8e18);
        uint64 capJTWAD = 1e12;
        uint64 capLPTWAD = 1e12;
        _enableLPTOverlay(capJTWAD, capLPTWAD, minLiquidityWAD);
        _flushPremiumAccrual();
        _warpForward(1 days);
        _applySTYield(0.02e18);

        // Arrange guard: both raw curve outputs must exceed the configured caps at the committed utilizations
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 coverageUtilizationWAD = _expectedCoverageUtilization(a.lastCollateralNAV, a.minCoverageWAD, a.lastJTEffectiveNAV);
        uint256 liquidityUtilizationWAD = _expectedLiquidityUtilization(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLPTRawNAV);
        vm.prank(address(ACCOUNTANT));
        uint256 rawJTYieldShareWAD = IYDM(a.jtYDM).previewYieldShare(a.lastMarketState, coverageUtilizationWAD);
        vm.prank(address(ACCOUNTANT));
        uint256 rawLPTYieldShareWAD = IYDM(a.lptYDM).previewYieldShare(a.lastMarketState, liquidityUtilizationWAD);
        assertGt(rawJTYieldShareWAD, capJTWAD, "arrange: the JT curve must price above its cap");
        assertGt(rawLPTYieldShareWAD, capLPTWAD, "arrange: the LPT curve must price above its cap");

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertEq(e.jtYieldShareWAD, capJTWAD, "the accrued JT yield share must bind at the cap");
        assertEq(e.lptYieldShareWAD, capLPTWAD, "the accrued LPT yield share must bind at the cap");

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.YieldSharesAccrued(
            capJTWAD, e.twJTStart + uint256(capJTWAD) * e.elapsed, capLPTWAD, e.twLPTStart + uint256(capLPTWAD) * e.elapsed
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
     *      equals the preview state the production view prices against. The final pricing conversion is an input.
     */
    function _expectedMaxSTDepositAssets() internal view returns (TRANCHE_UNIT assets) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 totalCoveredValue = Math.mulDiv(toUint256(a.lastJTEffectiveNAV), WAD, a.minCoverageWAD);
        uint256 requiredValue = toUint256(a.lastCollateralNAV) + toUint256(a.dustTolerance);
        return KERNEL.convertValueToCollateralAssets(toNAVUnits(totalCoveredValue > requiredValue ? totalCoveredValue - requiredValue : 0));
    }

    /**
     * @notice Independent recompute of the withdrawable pooled depth from the committed checkpoint.
     * @dev Mirrors `RoycoDayAccountant.maxLPTWithdrawal` below the liquidation threshold with a
     *      nonzero minimum liquidity, which callers must guarantee. Callers must have synced in the same block.
     */
    function _expectedMaxLPTWithdrawalNAV() internal view returns (NAV_UNIT) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 requiredValue = Math.mulDiv((toUint256(a.lastSTEffectiveNAV) + toUint256(a.dustTolerance)), a.minLiquidityWAD, WAD, Math.Rounding.Ceil);
        uint256 lptRawValue = toUint256(a.lastLPTRawNAV);
        return toNAVUnits(lptRawValue > requiredValue ? lptRawValue - requiredValue : 0);
    }

    /// @notice Asserts the reduction contract of a zero-liquidity market on a just-executed sync packet: no liquidity
    ///         premium, no LPT fee, zero liquidity utilization, and no staged premium senior shares anywhere.
    function _assertZeroLiquidityReduction(SyncedAccountingState memory _state) internal view {
        assertEq(_state.lptLiquidityPremium, ZERO_NAV_UNITS, "a zero-liquidity market must pay no liquidity premium");
        assertEq(_state.lptProtocolFee, ZERO_NAV_UNITS, "a zero-liquidity market must take no LPT protocol fee");
        assertEq(_state.liquidityUtilizationWAD, 0, "a zero-liquidity market must read zero liquidity utilization");
        assertEq(KERNEL.getState().lptOwnedSeniorTrancheShares, 0, "no premium senior shares may ever stage");
        assertEq(ST.balanceOf(address(KERNEL)), 0, "the kernel must never hold senior shares");
        _assertCommittedConservation();
    }

    /// @notice Per-tranche share-price inputs captured between the flagship sequence's steps.
    struct SeqPrices {
        uint256 stEffectiveNAV;
        uint256 stSupply;
        uint256 jtEffectiveNAV;
        uint256 jtSupply;
        uint256 lptEffectiveNAV;
        uint256 lptSupply;
    }

    /// @notice Captures the committed effective NAVs and live supplies that define each tranche's share price.
    /// @dev The LPT effective NAV is the committed BPT mark plus the claimable idle liquidity premium leg at the committed senior rate.
    function _seqSnapPrices() internal view returns (SeqPrices memory p) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        p.stEffectiveNAV = toUint256(a.lastSTEffectiveNAV);
        p.stSupply = ST.totalSupply();
        p.jtEffectiveNAV = toUint256(a.lastJTEffectiveNAV);
        p.jtSupply = JT.totalSupply();
        if (testConfig.hasLiquidityProviderTranche) {
            p.lptSupply = LPT.totalSupply();
            p.lptEffectiveNAV =
                toUint256(a.lastLPTRawNAV) + toUint256(_expectedValue(KERNEL.getState().lptOwnedSeniorTrancheShares, p.stSupply, a.lastSTEffectiveNAV));
        }
    }

    /**
     * @notice The flagship sequence's per-step check: committed conservation, kernel solvency, and share-price
     *         monotonicity against the previous step, compared as cross-multiplied integers.
     * @dev Non-decreasing comparisons tolerate one `maxNAVDelta()` of effective-NAV drift (a redemption's measured
     *      raw delta can exceed its floor-scaled claim NAV by pricing convexity). The expected
     *      junior price drop on the covered-loss step is asserted strictly. Zero-supply sides are skipped, since no
     *      price exists to compare.
     */
    function _seqCheckStep(SeqPrices memory _prev, bool _expectJTPriceDrop, bool _checkLPTPrice) internal view returns (SeqPrices memory cur) {
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
        if (_checkLPTPrice && _prev.lptSupply != 0 && cur.lptSupply != 0) {
            assertGe(
                (cur.lptEffectiveNAV + tolerance) * _prev.lptSupply,
                _prev.lptEffectiveNAV * cur.lptSupply,
                "sequence: the liquidity share price must not decrease"
            );
        }
    }

    // ── Donations are inert ──

    /**
     * @notice A direct collateral-asset transfer to the kernel is inert: the live and committed collateral NAV
     *         read the owned-asset ledger, share pricing is unchanged from a pre-donation expectation, and the
     *         donation only strengthens solvency.
     * @dev The donation is a real ERC20 transfer from a funded provider, never a forge `deal` (which would overwrite
     *      the balance instead of modeling a donation).
     */
    function test_Donation_assetToKernel_isInert() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applySTYield(0.02e18);
        _sync();

        // Pre-donation share-pricing expectation for the post-donation deposit
        uint256 assets = testConfig.initialFunding / 20;
        NAV_UNIT value = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(assets));
        uint256 expectedShares = _expectedShares(value, ST.totalSupply(), ACCOUNTANT.getState().lastSTEffectiveNAV);
        NAV_UNIT collateralRawBefore = _liveCollateralNAV();
        MarketSnapshot memory pre = _snap();

        uint256 donationAssets = testConfig.initialFunding / 10;
        vm.prank(ST_CHARLIE_ADDRESS);
        IERC20(COLLATERAL_ASSET).transfer(address(KERNEL), donationAssets);

        assertEq(_liveCollateralNAV(), collateralRawBefore, "the live collateral NAV must ignore the donated balance");
        _sync();
        MarketSnapshot memory post = _snap();
        assertEq(post.lastCollateralNAV, pre.lastCollateralNAV, "the committed collateral NAV must ignore the donation");
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV, "the committed senior effective NAV must ignore the donation");
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV, "the committed junior effective NAV must ignore the donation");
        assertEq(post.stSupply, pre.stSupply, "no shares may mint against a donation");

        // Solvency is now strictly overcollateralized by exactly the donated balance
        uint256 ledgerAssets = toUint256(KERNEL.getState().totalCollateralAssets);
        assertGe(IERC20(COLLATERAL_ASSET).balanceOf(address(KERNEL)) - ledgerAssets, donationAssets, "the donation must sit above the owned-asset ledger");

        OpReceipt memory r = _doDepositST(ST_BOB_ADDRESS, assets);
        assertEq(r.shares, expectedShares, "share pricing must be unchanged by the donation");
        _assertCommittedConservation();
    }

    /// @notice Direct asset transfers to the tranche contracts are inert: tranches never custody assets, so the
    ///         collateral NAV, sync, and share pricing are all unchanged.
    function test_Donation_toTranches_isInert() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();

        uint256 assets = testConfig.initialFunding / 20;
        NAV_UNIT value = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(assets));
        uint256 expectedSTShares = _expectedShares(value, ST.totalSupply(), ACCOUNTANT.getState().lastSTEffectiveNAV);
        uint256 expectedJTShares = _expectedShares(value, JT.totalSupply(), ACCOUNTANT.getState().lastJTEffectiveNAV);
        NAV_UNIT collateralNAVBefore = _liveCollateralNAV();
        MarketSnapshot memory pre = _snap();

        uint256 donationAssets = testConfig.initialFunding / 10;
        vm.prank(ST_CHARLIE_ADDRESS);
        IERC20(COLLATERAL_ASSET).transfer(address(ST), donationAssets);
        vm.prank(JT_CHARLIE_ADDRESS);
        IERC20(COLLATERAL_ASSET).transfer(address(JT), donationAssets);
        assertGe(IERC20(COLLATERAL_ASSET).balanceOf(address(ST)), donationAssets, "arrange: the senior tranche must hold the donated balance");

        assertEq(_liveCollateralNAV(), collateralNAVBefore, "the live collateral NAV must ignore assets donated to the tranches");
        _sync();
        MarketSnapshot memory post = _snap();
        assertEq(post.lastCollateralNAV, pre.lastCollateralNAV, "the committed collateral NAV must ignore the donations");
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV, "the committed senior effective NAV must ignore the donations");
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV, "the committed junior effective NAV must ignore the donations");

        assertEq(_doDepositST(ST_BOB_ADDRESS, assets).shares, expectedSTShares, "senior share pricing must be unchanged by the donations");
        assertEq(_doDepositJT(JT_BOB_ADDRESS, assets).shares, expectedJTShares, "junior share pricing must be unchanged by the donations");
        _assertCommittedConservation();
    }

    /**
     * @notice BPT and senior-share transfers to the kernel are inert: the committed LPT mark and the idle liquidity premium
     *         ledger are storage ledgers rather than balance reads, LPT share pricing is unchanged, and operations
     *         still succeed.
     */
    function test_Donation_bptAndSTSharesToKernel_isInert() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
        OpReceipt memory rRedeem = _doRedeemLPT(LPT_ALICE_ADDRESS, LPT.balanceOf(LPT_ALICE_ADDRESS) / 4);
        uint256 bptAssets = toUint256(rRedeem.claims.lptAssets);
        assertGt(bptAssets, 1, "arrange: the redemption must pay out BPT");
        _sync();

        // Pre-donation pricing expectation for an in-kind deposit of half of the withdrawn BPT
        uint256 bptDepositAssets = bptAssets / 2;
        NAV_UNIT value = KERNEL.convertLPTAssetsToValue(toTrancheUnits(bptDepositAssets));
        MarketSnapshot memory pre = _snap();
        assertEq(pre.lptOwnedSeniorTrancheShares, 0, "arrange: no staged premium may exist");
        uint256 expectedShares = _expectedShares(value, LPT.totalSupply(), pre.lastLPTRawNAV);

        // Donate the other half of the BPT plus live senior shares to the kernel
        uint256 bptDonationAssets = bptAssets - bptDepositAssets;
        vm.prank(LPT_ALICE_ADDRESS);
        IERC20(POOL).transfer(address(KERNEL), bptDonationAssets);
        uint256 stShareDonation = ST.balanceOf(ST_ALICE_ADDRESS) / 100;
        assertGt(stShareDonation, 0, "arrange: the senior share donation must be nonzero");
        vm.prank(ST_ALICE_ADDRESS);
        IERC20(address(ST)).transfer(address(KERNEL), stShareDonation);

        _sync();
        MarketSnapshot memory post = _snap();
        assertEq(post.lastLPTRawNAV, pre.lastLPTRawNAV, "the committed LPT mark must ignore the donated BPT");
        assertEq(post.lptOwnedSeniorTrancheShares, pre.lptOwnedSeniorTrancheShares, "the idle liquidity premium ledger must ignore the donated senior shares");
        assertEq(post.lptOwned, pre.lptOwned, "the owned BPT ledger must ignore the donation");
        assertEq(post.lastCollateralNAV, pre.lastCollateralNAV, "the committed collateral NAV must ignore the share donation");
        assertEq(post.kernelBPTBal, pre.kernelBPTBal + bptDonationAssets, "the kernel must hold the donated BPT above the ledger");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal + stShareDonation, "the kernel must hold the donated shares above the idle ledger");

        // LPT share pricing is unchanged and operations still succeed
        vm.startPrank(LPT_ALICE_ADDRESS);
        IERC20(POOL).approve(address(LPT), bptDepositAssets);
        uint256 shares = LPT.deposit(toTrancheUnits(bptDepositAssets), LPT_ALICE_ADDRESS);
        vm.stopPrank();
        assertEq(shares, expectedShares, "LPT share pricing must be unchanged by the donations");
        _assertSolvency();
        _assertCommittedConservation();
    }

    /**
     * @notice A quote-asset transfer to the pool contract address (not a venue join) leaves the market healthy: sync,
     *         LPT deposit, and LPT redemption all still succeed and conservation holds.
     * @dev Balancer V3 custodies pool tokens in its Vault, so balances at the pool address are venue-inert by design.
     */
    function test_Donation_quoteToPoolAddress_marketStillHealthy() public whenLPT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
        _sync();

        uint256 donationQuoteAssets = _quoteAssetsForValue(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(testConfig.initialFunding / 1000)));
        assertGt(donationQuoteAssets, 0, "arrange: the quote donation must be nonzero");
        vm.prank(LPT_BOB_ADDRESS);
        IERC20(testConfig.quoteAsset).transfer(POOL, donationQuoteAssets);

        _sync();
        uint256 quoteDepositAssets = _quoteAssetsForValue(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(testConfig.initialFunding / 1000)));
        assertGt(_doDepositLPTMulti(LPT_BOB_ADDRESS, 0, quoteDepositAssets, 0).shares, 0, "an LPT deposit must still succeed after the donation");
        OpReceipt memory r = _doRedeemLPT(LPT_ALICE_ADDRESS, LPT.balanceOf(LPT_ALICE_ADDRESS) / 10);
        assertGt(toUint256(r.claims.lptAssets), 0, "an LPT redemption must still pay out after the donation");
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
        while (toUint256(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(attackerAssets))) == 0) {
            attackerAssets *= 10;
        }
        OpReceipt memory rAttacker = _doDepositST(ST_BOB_ADDRESS, attackerAssets);
        assertGt(rAttacker.shares, 0, "arrange: the attacker must hold shares");

        // The attacker transfer-donates a large collateral balance to the kernel
        uint256 donationAssets = testConfig.initialFunding / 10;
        vm.prank(ST_BOB_ADDRESS);
        IERC20(COLLATERAL_ASSET).transfer(address(KERNEL), donationAssets);
        _sync();

        // The victim's expectation prices off the committed (donation-free) checkpoint
        uint256 victimAssets = testConfig.initialFunding / 10;
        NAV_UNIT victimValue = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(victimAssets));
        uint256 expectedVictimShares = _expectedShares(victimValue, ST.totalSupply(), ACCOUNTANT.getState().lastSTEffectiveNAV);
        assertGt(expectedVictimShares, 0, "the victim's shares must not floor to zero");

        OpReceipt memory rVictim = _doDepositST(ST_ALICE_ADDRESS, victimAssets);
        assertEq(rVictim.shares, expectedVictimShares, "the donation must not move the victim's share pricing");
        assertApproxEqAbs(
            rVictim.post.lastCollateralNAV - rAttacker.post.lastCollateralNAV,
            victimValue,
            maxNAVDelta(),
            "the committed collateral NAV must grow only by the victim's deposit"
        );
        NAV_UNIT victimHoldingValue = _expectedValue(rVictim.shares, rVictim.post.stSupply, rVictim.post.lastSTEffectiveNAV);
        assertApproxEqAbs(victimHoldingValue, victimValue, maxNAVDelta(), "the victim's holding must round-trip its deposit value");
        _assertCommittedConservation();
    }

    /**
     * @notice A deposit-before-gain sandwich extracts no more than the attacker's pro-rata slice of the booked senior
     *         gain, and never less than its principal on a gain window, both within pricing dust.
     * @dev Bound derivation: `valueOut = floor(stEff1 * shares / S1) <= (stEff0 + G) * shares / S0` since `S1 >= S0`,
     *      and the deposit's floor share pricing makes `stEff0 * shares / S0 <= valueIn` up to a wei of rounding, so
     *      `valueOut <= valueIn + floor(G * shares / S0)` within `maxNAVDelta()`. Fees and premiums only tighten it.
     */
    function test_Sandwich_depositBeforeSyncGain_profitBounded() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();

        OpReceipt memory rIn = _doDepositST(ST_BOB_ADDRESS, testConfig.initialFunding / 10);
        uint256 valueIn = toUint256(rIn.post.lastCollateralNAV - rIn.pre.lastCollateralNAV);
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
     * @notice PINS the zero-BPT-slice edge: an LPT redemption whose BPT slice floors to zero while its idle premium
     *         slice is nonzero commits as a NAV-neutral redemption, handing the redeemer exactly its pro-rata idle
     *         senior-share slice while the floored BPT leg pays nothing.
     * @dev The idle premium is a claimable leg of the LPT's effective NAV. Handing the senior shares over moves no raw
     *      NAV (they stay in the senior supply), so the LPT_REDEEM shape check (a redemption never grows the LPT's
     *      deployed raw NAV) commits it. The arranged market is liquidity-healthy (utilization ~0.8), so the liquidity
     *      requirement passes and the premium is delivered rather than stranded.
     */
    function test_LPTRedeem_zeroBPTSlice_nonzeroIdle_pinned() public whenLPT {
        uint256 idleShares = _arrangeStagedIdleLiquidityPremium();

        uint256 lptSupply = LPT.totalSupply();
        uint256 lptOwnedAssets = toUint256(KERNEL.getState().totalLPTAssets);
        // The largest share count whose proportional BPT slice floors to zero
        uint256 shares = (lptSupply - 1) / lptOwnedAssets;
        assertGt(shares, 0, "arrange: the BPT-per-share ratio must make a zero-BPT slice representable");
        assertLe(shares, LPT.balanceOf(LPT_ALICE_ADDRESS), "arrange: the redeemer must afford the dust redemption");
        assertEq(Math.mulDiv(lptOwnedAssets, shares, lptSupply), 0, "arrange: the BPT slice must floor to zero");
        uint256 expectedIdleSlice = Math.mulDiv(idleShares, shares, lptSupply);
        assertGt(expectedIdleSlice, 0, "arrange: the idle liquidity premium slice must be nonzero");

        uint256 aliceSTPre = ST.balanceOf(LPT_ALICE_ADDRESS);
        OpReceipt memory r = _doRedeemLPT(LPT_ALICE_ADDRESS, shares);

        // Exactly the pro-rata idle senior shares are handed over in kind, the floored BPT leg pays nothing, and the
        // kernel's idle pile drops by exactly that slice
        assertEq(r.claims.stShares, expectedIdleSlice, "the in-kind redeem must pay exactly the pro-rata idle senior share slice");
        assertEq(toUint256(r.claims.lptAssets), 0, "the floored BPT leg must pay nothing in kind");
        assertEq(ST.balanceOf(LPT_ALICE_ADDRESS) - aliceSTPre, expectedIdleSlice, "the redeemer must receive exactly its idle senior share slice");
        assertEq(r.post.lptOwnedSeniorTrancheShares, idleShares - expectedIdleSlice, "the kernel's idle pile must drop by exactly the redeemed slice");
        _assertCommittedConservation();
    }

    /**
     * @notice PINS the zero-NAV live-supply edge (with the mint-dilution clamp): a JT deposit against a
     *         live supply with zero junior effective NAV prices against the documented one-wei denominator and
     *         BINDS the clamp, so the depositor takes over the tranche up to the 1e-12 residual, the mint is
     *         exactly cap = floor(supply x (WAD - eps) / eps) instead of the pre-clamp unbounded supply x value ,
     *         and the pre-existing unbacked holder is diluted to its floor-scaled dust claim.
     */
    function test_JTDeposit_zeroNAVLiveSupply_pinned() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 16);
        _sync();

        // A loss large enough that coverage exhausts the junior effective NAV to exactly zero: a rate loss of
        // fraction p exhausts JT once p >= jtEff / collateralNAV (the residual-loss test's derivation), padded 2 percent
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        uint256 lossPctWAD = Math.mulDiv(toUint256(a0.lastJTEffectiveNAV), WAD, toUint256(a0.lastCollateralNAV), Math.Rounding.Ceil) + 0.02e18;
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
        NAV_UNIT value = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(assets));
        uint256 expectedShares = _expectedShares(value, jtSupplyPre, ZERO_NAV_UNITS);
        assertGt(toUint256(value) * (WAD - MAX_MINT_DILUTION), MAX_MINT_DILUTION, "arrange: the dilution deposit must bind the clamp");
        // The clamp cap now prices against the effective supply (jtSupplyPre + VIRTUAL_SHARES) per the offset
        assertEq(
            expectedShares,
            Math.mulDiv(jtSupplyPre + VIRTUAL_SHARES, MAX_MINT_DILUTION, WAD - MAX_MINT_DILUTION),
            "the zero-NAV branch must clamp to the dilution cap against the effective supply"
        );

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
     * @notice PINS the post-liquidation-breach per-tranche withdrawal rules: senior redemptions pay the bonus, LPT
     *         redemptions stay liquidity-gated with only a bounded surplus reported withdrawable and an
     *         over-floor in-kind redemption reverting, and junior redemptions stay coverage-gated with zero
     *         reported capacity.
     */
    function test_LiquidationBreach_perTrancheWithdrawalRules() public whenLPT {
        _ensureSelfLiquidationBonusConfigured();
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLPT();
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
        (, NAV_UNIT lptMaxWithdrawableNAV,) = KERNEL.lptMaxWithdrawable(LPT_ALICE_ADDRESS);
        assertLt(lptMaxWithdrawableNAV, pre.lastLPTRawNAV, "the liquidation breach must not waive the pooled-depth liquidity floor");
        assertLt(LPT.maxRedeem(LPT_ALICE_ADDRESS), LPT.balanceOf(LPT_ALICE_ADDRESS), "lptMaxRedeem must stay bounded below the full balance");

        // (b) An in-kind LPT redemption that overruns the liquidity floor reverts even during the breach
        uint256 lptShares = (LPT.balanceOf(LPT_ALICE_ADDRESS) * 3) / 4;
        _assertSliceWouldBreachLiquidity(lptShares, minLiquidityWAD, pre);
        vm.prank(LPT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        LPT.redeem(lptShares, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);

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
     * @notice PINS the staleness brick: past the oracle staleness threshold every quoting surface reverts with the
     *         venue's staleness selector, mutating flows (deposit and sync) and the view preview alike, and a fresh
     *         oracle update resumes the market.
     * @dev The raw `vm.warp` without an oracle refresh is the brick under test, deliberately bypassing the sanctioned
     *      `_warpForward`. The 30-day jump dominates any realistic staleness threshold configuration. Views brick too
     *      because the transient price cache only lives inside a mutating operation and the un-cached view fallback
     *      re-queries the live oracle through the same staleness gate.
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
        IERC20(COLLATERAL_ASSET).approve(address(ST), assets);
        vm.expectRevert(staleSelector);
        ST.deposit(toTrancheUnits(assets), ST_ALICE_ADDRESS);
        vm.stopPrank();

        vm.prank(SYNC_ROLE_ADDRESS);
        vm.expectRevert(staleSelector);
        KERNEL.syncTrancheAccounting();

        // The view surface bricks identically since the transient cache is cleared at the end of every operation
        vm.expectRevert(staleSelector);
        KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);

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
        if (testConfig.hasLiquidityProviderTranche) {
            _seedDefaultLPT();
            bptAssets = toUint256(_doRedeemLPT(LPT_ALICE_ADDRESS, LPT.balanceOf(LPT_ALICE_ADDRESS) / 10).claims.lptAssets);
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
        IERC20(COLLATERAL_ASSET).approve(address(ST), assets);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        ST.deposit(toTrancheUnits(assets), ST_ALICE_ADDRESS);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        ST.redeem(1, ST_ALICE_ADDRESS, ST_ALICE_ADDRESS);
        vm.stopPrank();

        vm.startPrank(JT_ALICE_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(JT), assets);
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

        if (testConfig.hasLiquidityProviderTranche) {
            assertEq(LPT.maxDeposit(LPT_ALICE_ADDRESS), ZERO_TRANCHE_UNITS, "lptMaxDeposit must report zero while paused");
            assertEq(LPT.maxRedeem(LPT_ALICE_ADDRESS), 0, "lptMaxRedeem must report zero while paused");
            uint256 quoteAssets = 10 ** IERC20Metadata(testConfig.quoteAsset).decimals();
            vm.startPrank(LPT_ALICE_ADDRESS);
            IERC20(POOL).approve(address(LPT), bptAssets);
            vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
            LPT.deposit(toTrancheUnits(bptAssets), LPT_ALICE_ADDRESS);
            vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
            LPT.redeem(1, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);
            IERC20(testConfig.quoteAsset).approve(address(LPT), quoteAssets);
            vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
            IRoycoLiquidityProviderTranche(address(LPT)).depositMultiAsset(0, quoteAssets, 0, LPT_ALICE_ADDRESS);
            vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
            IRoycoLiquidityProviderTranche(address(LPT)).redeemMultiAsset(1, 0, 0, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);
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
        IERC20(COLLATERAL_ASSET).approve(address(ST), assets);
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
     * @notice The blacklist screens the junior and liquidity provider tranche flows identically to the senior: a
     *         blacklisted account can neither receive a deposit, transfer its shares out, nor redeem them on
     *         either tranche, every max view zeroes, and the deliberately-public LPT deposit surface is
     *         screened at the share mint.
     */
    function test_Blacklist_deniesJTAndLPTFlows() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        address eve = JT_CHARLIE_ADDRESS;
        uint256 assets = testConfig.initialFunding / 100;
        uint256 eveJTShares = _doDepositJT(eve, assets).shares;
        assertGt(eveJTShares, 0, "arrange: eve must hold junior shares before being blacklisted");

        uint256 eveLPTShares;
        if (testConfig.hasLiquidityProviderTranche) {
            _seedDefaultLPT();
            // Grant eve the LPT LP role so the blacklist screen (not the auth gate) is what rejects the LPT flows
            vm.prank(LP_ROLE_ADMIN_ADDRESS);
            ACCESS_MANAGER.grantRole(LPT_LP_ROLE, eve, 0);
            eveLPTShares = LPT.balanceOf(LPT_ALICE_ADDRESS) / 10;
            vm.prank(LPT_ALICE_ADDRESS);
            LPT.transfer(eve, eveLPTShares);
            assertGt(eveLPTShares, 0, "arrange: eve must hold liquidity shares before being blacklisted");
        }
        _blacklist(eve);
        bytes memory blacklistedError = abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, eve);

        // Junior tranche: deposit-to, transfer-out, and redeem are all screened, and the max views zero
        vm.startPrank(JT_ALICE_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(JT), assets);
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

        if (testConfig.hasLiquidityProviderTranche) {
            // A roled LPT depositor is still screened at the share mint: it cannot mint to a blacklisted receiver
            uint256 quoteAssets = _quoteAssetsForValue(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(testConfig.initialFunding / 1000)));
            vm.startPrank(LPT_BOB_ADDRESS);
            IERC20(testConfig.quoteAsset).approve(address(LPT), quoteAssets);
            vm.expectRevert(blacklistedError);
            IRoycoLiquidityProviderTranche(address(LPT)).depositMultiAsset(0, quoteAssets, 0, eve);
            vm.stopPrank();
            // Held LPT shares can neither transfer out nor redeem on either flow, and the max views zero
            vm.prank(eve);
            vm.expectRevert(blacklistedError);
            LPT.transfer(LPT_BOB_ADDRESS, eveLPTShares);
            vm.prank(eve);
            vm.expectRevert(blacklistedError);
            LPT.redeem(eveLPTShares, eve, eve);
            vm.prank(eve);
            vm.expectRevert(blacklistedError);
            IRoycoLiquidityProviderTranche(address(LPT)).redeemMultiAsset(eveLPTShares, 0, 0, eve, eve);
            assertEq(LPT.maxDeposit(eve), ZERO_TRANCHE_UNITS, "lptMaxDeposit must report zero for a blacklisted receiver");
            assertEq(LPT.maxRedeem(eve), 0, "lptMaxRedeem must report zero for a blacklisted owner");
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
        if (testConfig.hasLiquidityProviderTranche) _seedDefaultLPT();
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
        if (testConfig.hasLiquidityProviderTranche) {
            vm.expectRevert(unauthorizedError);
            LPT.deposit(toTrancheUnits(assets), outsider);
            vm.expectRevert(unauthorizedError);
            IRoycoLiquidityProviderTranche(address(LPT)).depositMultiAsset(0, assets, 0, outsider);
            vm.expectRevert(unauthorizedError);
            LPT.redeem(1, outsider, outsider);
            vm.expectRevert(unauthorizedError);
            IRoycoLiquidityProviderTranche(address(LPT)).redeemMultiAsset(1, 0, 0, outsider, outsider);
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
        KERNEL.stDeposit(false, toTrancheUnits(1));
        vm.expectRevert(IRoycoDayKernel.ONLY_SENIOR_TRANCHE.selector);
        KERNEL.stRedeem(false, 1, outsider);
        vm.expectRevert(IRoycoDayKernel.ONLY_JUNIOR_TRANCHE.selector);
        KERNEL.jtDeposit(false, toTrancheUnits(1));
        vm.expectRevert(IRoycoDayKernel.ONLY_JUNIOR_TRANCHE.selector);
        KERNEL.jtRedeem(false, 1, outsider);
        if (testConfig.hasLiquidityProviderTranche) {
            vm.expectRevert(IRoycoDayKernel.ONLY_LIQUIDITY_PROVIDER_TRANCHE.selector);
            KERNEL.lptDeposit(false, toTrancheUnits(1));
            vm.expectRevert(IRoycoDayKernel.ONLY_LIQUIDITY_PROVIDER_TRANCHE.selector);
            KERNEL.lptRedeem(false, 1, outsider);
            // The multi-asset pair in both preview modes: a direct call with _isPreview true would commit the
            // flow's mutations with no outer preview revert to unwind them, so this gate is the sole defense
            vm.expectRevert(IRoycoDayKernel.ONLY_LIQUIDITY_PROVIDER_TRANCHE.selector);
            KERNEL.lptDepositMultiAsset(false, toTrancheUnits(1), 1, ZERO_TRANCHE_UNITS);
            vm.expectRevert(IRoycoDayKernel.ONLY_LIQUIDITY_PROVIDER_TRANCHE.selector);
            KERNEL.lptDepositMultiAsset(true, toTrancheUnits(1), 1, ZERO_TRANCHE_UNITS);
            vm.expectRevert(IRoycoDayKernel.ONLY_LIQUIDITY_PROVIDER_TRANCHE.selector);
            KERNEL.lptRedeemMultiAsset(false, 1, 0, 0, outsider);
            vm.expectRevert(IRoycoDayKernel.ONLY_LIQUIDITY_PROVIDER_TRANCHE.selector);
            KERNEL.lptRedeemMultiAsset(true, 1, 0, 0, outsider);
            vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
            KERNEL.addLiquidity(false, 1, 1, ZERO_TRANCHE_UNITS);
            vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
            KERNEL.removeLiquidity(false, toTrancheUnits(1), 0, 0, outsider);
            vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
            KERNEL.attemptLiquidityPremiumReinvestment(1, ZERO_NAV_UNITS, 0);
        }
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        ACCOUNTANT.preOpSyncTrancheAccounting(ZERO_NAV_UNITS);
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        ACCOUNTANT.commitLiquidityProviderTrancheRawNAV(ZERO_NAV_UNITS);
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        ACCOUNTANT.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
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
     * @dev Two arrangement notes: the LPT is seeded before the overlay is enabled (each
     *      chunked seeding deposit enforces the liquidity gate post-op, so a pre-set minimum against an empty pool
     *      reverts by design), and LPT price monotonicity is skipped only across the reinvestment step, whose venue add
     *      pays real slippage bounded by the opened gate rather than accruing a lossless mark.
     */
    function test_Sequence_dayInTheLife() public whenLPT {
        vm.skip(!_trySetReinvestmentSlippage(0));
        _setupLPTProviders();
        uint256 funding = testConfig.initialFunding;
        SeqPrices memory p = _seqSnapPrices();

        // (1) JT_ALICE collateralizes and (2) ST_ALICE enters under coverage
        _depositJT(JT_ALICE_ADDRESS, funding / 4);
        p = _seqCheckStep(p, false, false);
        _depositST(ST_ALICE_ADDRESS, funding / 2);
        p = _seqCheckStep(p, false, false);

        // (3) A dust-deep LPT is seeded, then (4) the overlay is enabled against it
        _seedLPTBalanced(LPT_ALICE_ADDRESS, funding / 20_000);
        p = _seqCheckStep(p, false, true);
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.3e18);
        _enableLPTOverlay(0.1e18, 0.5e18, minLiquidityWAD);
        p = _seqCheckStep(p, false, true);

        // (5) The first premium window accrues and stages against the dust pool (the shut gate is the second belt)
        _warpForward(1 days);
        _applySTYield(0.02e18);
        _sync();
        assertGt(KERNEL.getState().lptOwnedSeniorTrancheShares, 0, "the liquidity premium must stage idle against the dust pool");
        p = _seqCheckStep(p, false, true);

        // (6) LPT_BOB enters at dust scale, keeping the pool shallow so the staged premium cannot deploy early
        uint256 idleBeforeEntry = KERNEL.getState().lptOwnedSeniorTrancheShares;
        _seedLPTBalanced(LPT_BOB_ADDRESS, funding / 50_000);
        assertEq(KERNEL.getState().lptOwnedSeniorTrancheShares, idleBeforeEntry, "the LPT entry must not consume the staged premium");
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
        uint256 idleBeforeReinvest = KERNEL.getState().lptOwnedSeniorTrancheShares;
        assertGt(idleBeforeReinvest, 0, "arrange: staged premium must exist for the reinvestment");

        // (12) The pool deepens flat (no premium mints, so the idle survives), the gate opens, and the staged
        //      premium deploys into the real depth
        _seedLPTBalanced(LPT_BOB_ADDRESS, funding / 100);
        assertEq(KERNEL.getState().lptOwnedSeniorTrancheShares, idleBeforeReinvest, "deepening the pool must not consume the staged premium");
        assertTrue(_trySetReinvestmentSlippage(uint64(WAD - 1)), "arrange: the slippage gate must open");
        NAV_UNIT lptRawBeforeReinvest = ACCOUNTANT.getState().lastLPTRawNAV;
        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(type(uint256).max);
        assertEq(KERNEL.getState().lptOwnedSeniorTrancheShares, 0, "the staged premium must fully deploy");
        assertGt(ACCOUNTANT.getState().lastLPTRawNAV, lptRawBeforeReinvest, "the committed depth must grow on deployment");
        p = _seqCheckStep(p, false, false);

        // (13) LPT_ALICE exits half via the multi-asset unwind
        OpReceipt memory rMulti = _doRedeemLPTMulti(LPT_ALICE_ADDRESS, LPT.balanceOf(LPT_ALICE_ADDRESS) / 2, 0, 0);
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
     * @notice The zero-minimum-liquidity reduction acceptance test in fork form: a market with the LPT overlay off behaves as
     *         a plain ST/JT market through deposits, yield, loss, redemptions, and a max-size senior deposit, with no
     *         liquidity premium, zero liquidity utilization, and no staged premium at any sync.
     */
    function test_Sequence_zeroLiquidityReduction_behavesAsPlainSTJT() public {
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        vm.skip(a0.minLiquidityWAD != 0 || a0.maxLPTYieldShareWAD != 0);

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
        // Counterweight independent of the max-deposit mirror: the reported maximum, valued through the pricing path,
        // must itself fit under the coverage gate's defining inequality, depositing it leaves the collateral
        // NAV times the minimum coverage within the junior effective NAV (plain cross-multiplied integers).
        assertLe(
            (toUint256(a0.lastCollateralNAV) + toUint256(KERNEL.convertCollateralAssetsToValue(maxDepositBefore))) * uint256(a0.minCoverageWAD),
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
        if (testConfig.hasLiquidityProviderTranche) {
            _seedDefaultLPT();
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
            (, NAV_UNIT maxWithdrawableA,) = KERNEL.lptMaxWithdrawable(LPT_ALICE_ADDRESS);
            assertEq(maxWithdrawableA, _expectedMaxLPTWithdrawalNAV(), "lptMaxWithdrawable must match the independent recompute");
            assertGt(toUint256(maxWithdrawableA), 0, "arrange: the liquidity surplus must be nonzero");
            // Counterweights independent of the max-withdrawal mirror: the withdrawable depth can never exceed the
            // pooled depth itself, and removing it must leave enough depth to satisfy the liquidity requirement
            // (remaining lptRawNAV * WAD >= stEffectiveNAV * minLiquidity, plain cross-multiplied integers).
            IRoycoDayAccountant.RoycoDayAccountantState memory aL = ACCOUNTANT.getState();
            assertLe(toUint256(maxWithdrawableA), toUint256(aL.lastLPTRawNAV), "the withdrawable depth cannot exceed the pooled depth");
            assertGe(
                (toUint256(aL.lastLPTRawNAV) - toUint256(maxWithdrawableA)) * WAD,
                toUint256(aL.lastSTEffectiveNAV) * uint256(aL.minLiquidityWAD),
                "the reported max withdrawal must leave the liquidity requirement satisfied"
            );

            _setMinLiquidityWAD(minLiquidityA * 2);
            _sync();
            (, NAV_UNIT maxWithdrawableB,) = KERNEL.lptMaxWithdrawable(LPT_ALICE_ADDRESS);
            assertEq(maxWithdrawableB, _expectedMaxLPTWithdrawalNAV(), "lptMaxWithdrawable must match the independent recompute after the raise");
            assertLt(maxWithdrawableB, maxWithdrawableA, "raising the liquidity requirement must shrink the withdrawable depth");
        }
        _assertCommittedConservation();
    }
}
