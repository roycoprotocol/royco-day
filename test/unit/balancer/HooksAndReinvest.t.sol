// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVaultErrors } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";
import {
    AddLiquidityKind,
    HookFlags,
    PoolSwapParams,
    RemoveLiquidityKind,
    SwapKind
} from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SYNC_ROLE } from "../../../src/factory/RolesConfiguration.sol";
import { RoycoDayBalancerV3Hooks } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/RoycoDayBalancerV3Hooks.sol";
import { RoycoDayBalancerV3HooksStandIn } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/RoycoDayBalancerV3HooksStandIn.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../base/fixtures/MarketParams.sol";
import { cellA } from "../../base/fixtures/TokenConfigs.sol";
import { TrancheFixture } from "../../base/fixtures/TrancheFixture.sol";

/**
 * @title HooksAndReinvestTest
 * @notice Balancer battery B5–B8: the pool hooks' sync-before-external-op behavior (incl. the kernel carve-out, the
 *         SYNC_ROLE liveness dependency, pause, and the wrong-pool guard), the stand-in/real hook-flag freeze
 *         equivalence, the reinvestment slippage-gate ceil boundary from both sides, and multi-asset preview parity
 *         under a non-trivial venue fee.
 * @dev Mock-based (cell A, default params). The hooks contract does not exist in the fixture's mock market, so each
 *      hook test deploys the REAL RoycoDayBalancerV3Hooks proxy against the fixture's kernel and mock vault — the
 *      exact production wiring minus Balancer's dispatch, which the tests stand in for by pranking the vault.
 */
contract HooksAndReinvestTest is TrancheFixture {
    RoycoDayBalancerV3Hooks internal hooks;

    function setUp() public virtual {
        _deployMarket(cellA(), defaultParams());
        // Real hook implementation + proxy against the fixture kernel (ctor derives the pool and vault from it).
        RoycoDayBalancerV3Hooks hookImpl = new RoycoDayBalancerV3Hooks(address(kernel));
        hooks = RoycoDayBalancerV3Hooks(
            address(new ERC1967Proxy(address(hookImpl), abi.encodeCall(RoycoDayBalancerV3Hooks.initialize, (address(accessManager)))))
        );
        // Production grants the hook SYNC_ROLE so external pool ops can sync the kernel (the no-role case is B5's
        // liveness test, which deploys its own ungranted hook).
        accessManager.grantRole(SYNC_ROLE, address(hooks), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // B5 — hooks sync-before-external-operation (RoycoDayBalancerV3Hooks.sol:80-127)
    // ═══════════════════════════════════════════════════════════════════════════

    /// An externally-routed swap syncs the kernel BEFORE the swap: unrealized senior PnL lands in the committed
    /// checkpoint. Expected committed stRaw is hand-derived: ownedAssets x vault-rate x feed (all WAD, cell A).
    function test_onBeforeSwap_syncsKernel_committingUnrealizedPnL() external {
        _seedMarket(100e18, 50e18);
        applySTPnL(1000); // +10%: vault rate 1.0 -> 1.1

        uint256 ownedAssets = toUint256(kernel.getState().stOwnedYieldBearingAssets);
        uint256 expectedStRaw = Math.mulDiv(ownedAssets, 1.1e18, 1e18, Math.Rounding.Floor); // 4626 rate leg
        assertTrue(toUint256(accountant.getState().lastSTRawNAV) != expectedStRaw, "arrange: PnL is uncommitted");

        vm.prank(address(balancerVault));
        bool ok = hooks.onBeforeSwap(_swapParams(makeAddr("EXTERNAL_ROUTER")), address(bpt));

        assertTrue(ok, "hook returns true");
        assertEq(toUint256(accountant.getState().lastSTRawNAV), expectedStRaw, "sync committed the senior PnL before the swap");
    }

    /// External add/remove liquidity hooks sync identically (same path as the swap hook).
    function test_onBeforeAddAndRemoveLiquidity_externalRouter_syncs() external {
        _seedMarket(100e18, 50e18);

        applySTPnL(500); // +5%
        vm.prank(address(balancerVault));
        assertTrue(
            hooks.onBeforeAddLiquidity(makeAddr("EXTERNAL_ROUTER"), address(bpt), AddLiquidityKind.UNBALANCED, new uint256[](2), 0, new uint256[](2), ""),
            "add hook true"
        );
        uint256 committedAfterAdd = toUint256(accountant.getState().lastSTRawNAV);
        uint256 ownedAssets = toUint256(kernel.getState().stOwnedYieldBearingAssets);
        assertEq(committedAfterAdd, Math.mulDiv(ownedAssets, 1.05e18, 1e18, Math.Rounding.Floor), "add hook synced");

        applySTPnL(500); // a further +5% on the new rate: 1.05 * 1.05 = 1.1025
        vm.prank(address(balancerVault));
        assertTrue(
            hooks.onBeforeRemoveLiquidity(
                makeAddr("EXTERNAL_ROUTER"), address(bpt), RemoveLiquidityKind.PROPORTIONAL, 0, new uint256[](2), new uint256[](2), ""
            ),
            "remove hook true"
        );
        assertEq(toUint256(accountant.getState().lastSTRawNAV), Math.mulDiv(ownedAssets, 1.1025e18, 1e18, Math.Rounding.Floor), "remove hook synced");
    }

    /// The kernel carve-out: kernel-routed liquidity ops SKIP the hook sync (the outer LT flow brackets the op with
    /// its own pre/post syncs). Uncommitted PnL must remain uncommitted across the hook call.
    function test_onBeforeAddLiquidity_kernelRouter_skipsSync() external {
        _seedMarket(100e18, 50e18);
        applySTPnL(1000);
        uint256 committedBefore = toUint256(accountant.getState().lastSTRawNAV);

        vm.prank(address(balancerVault));
        bool ok = hooks.onBeforeAddLiquidity(address(kernel), address(bpt), AddLiquidityKind.UNBALANCED, new uint256[](2), 0, new uint256[](2), "");

        assertTrue(ok, "carve-out returns true without syncing");
        assertEq(toUint256(accountant.getState().lastSTRawNAV), committedBefore, "committed checkpoint untouched by the kernel-routed hook");
    }

    /// A hook invoked for a pool other than this market's LT pool is rejected.
    function test_hooks_revert_wrongPool() external {
        vm.prank(address(balancerVault));
        vm.expectRevert(RoycoDayBalancerV3Hooks.ONLY_LIQUIDITY_TRANCHE_BALANCER_V3_POOL.selector);
        hooks.onBeforeSwap(_swapParams(makeAddr("EXTERNAL_ROUTER")), makeAddr("FOREIGN_POOL"));
    }

    /// Hook callbacks are vault-only: any other caller is rejected with Balancer's SenderIsNotVault.
    function test_hooks_revert_nonVaultCaller() external {
        vm.prank(makeAddr("NOT_THE_VAULT"));
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, makeAddr("NOT_THE_VAULT")));
        hooks.onBeforeSwap(_swapParams(makeAddr("EXTERNAL_ROUTER")), address(bpt));
    }

    /// A paused hook blocks every externally-routed pool operation (the sync helper is whenNotPaused). The kernel
    /// carve-out is NOT affected: kernel-routed ops return before the paused sync helper.
    function test_hooks_paused_blocksExternalOps_butNotKernelRoutedOps() external {
        _seedMarket(100e18, 50e18);
        // `pause` is unbound on this ad-hoc proxy, so it defaults to ADMIN_ROLE — held by this fixture contract.
        hooks.pause();

        vm.prank(address(balancerVault));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        hooks.onBeforeSwap(_swapParams(makeAddr("EXTERNAL_ROUTER")), address(bpt));

        // Kernel-routed liquidity ops skip the sync helper entirely, so they survive the hook pause.
        vm.prank(address(balancerVault));
        assertTrue(
            hooks.onBeforeAddLiquidity(address(kernel), address(bpt), AddLiquidityKind.UNBALANCED, new uint256[](2), 0, new uint256[](2), ""),
            "kernel-routed add unaffected by hook pause"
        );
    }

    /// Liveness dependency pinned: a hook WITHOUT SYNC_ROLE makes every external pool op revert
    /// AccessManagedUnauthorized(hook) — a deploy-time grant omission produces an operationally dead pool.
    function test_hooks_withoutSyncRole_externalOpsRevert() external {
        _seedMarket(100e18, 50e18);
        RoycoDayBalancerV3Hooks hookImpl = new RoycoDayBalancerV3Hooks(address(kernel));
        RoycoDayBalancerV3Hooks ungranted = RoycoDayBalancerV3Hooks(
            address(new ERC1967Proxy(address(hookImpl), abi.encodeCall(RoycoDayBalancerV3Hooks.initialize, (address(accessManager)))))
        );

        vm.prank(address(balancerVault));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(ungranted)));
        ungranted.onBeforeSwap(_swapParams(makeAddr("EXTERNAL_ROUTER")), address(bpt));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // B6 — stand-in / real hook flag freeze equivalence
    // ═══════════════════════════════════════════════════════════════════════════

    /// Balancer freezes hook flags at registration against the STAND-IN; the real hook lands by upgrade afterward.
    /// The two flag sets must be byte-identical or a real-hook callback silently never fires (the one non-reverting
    /// mis-wire in the deployment design).
    function test_hookFlags_standInMatchesRealHookExactly() external {
        RoycoDayBalancerV3HooksStandIn standIn = new RoycoDayBalancerV3HooksStandIn();
        HookFlags memory standInFlags = standIn.getHookFlags();
        HookFlags memory realFlags = hooks.getHookFlags();
        assertEq(keccak256(abi.encode(standInFlags)), keccak256(abi.encode(realFlags)), "flag sets must be byte-identical");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // B7 — reinvestment slippage-gate ceil boundary (BalancerV3VenueLogic.sol)
    // ═══════════════════════════════════════════════════════════════════════════

    /// The gate floors the add at minOut = ceil(fairBPT * (WAD - maxSlippage) / WAD). Pinned from BOTH sides on the
    /// same staged premium pile: a venue minting exactly minOut-1 defers (tolerated failure, idle pile and committed
    /// state untouched); a venue minting exactly minOut deploys the entire pile and credits exactly minOut BPT.
    function test_reinvestmentGate_ceilBoundary_bothSides() external {
        uint256 idle = _stageIdlePremium();

        // Derive the gate's exact floor from committed state, mirroring the production formula:
        //   fairNAV  = floor(stEff * idle / stSupply)                       (ValuationLogic._convertToValue)
        //   fairBPT  = floor(bptSupply * fairNAV / TVL)                     (ltConvertNAVUnitsToTrancheUnits)
        //   minOut   = ceil(fairBPT * (WAD - maxSlippage) / WAD)
        uint256 stEff = toUint256(accountant.getState().lastSTEffectiveNAV);
        uint256 stSupply = seniorTranche.totalSupply();
        uint256 fairNAV = Math.mulDiv(stEff, idle, stSupply, Math.Rounding.Floor);
        uint256 fairBPT = Math.mulDiv(balancerVault.totalSupply(address(bpt)), fairNAV, bptOracle.computeTVL(), Math.Rounding.Floor);
        uint256 minOut = Math.mulDiv(fairBPT, WAD - params.maxReinvestmentSlippageWAD, WAD, Math.Rounding.Ceil);
        assertGt(minOut, 1, "arrange: boundary must be expressible from both sides");

        uint256 ltOwnedBefore = toUint256(kernel.getState().ltOwnedYieldBearingAssets);

        // Side 1: one wei under the gate => the inner add reverts, the failure is tolerated, and NOTHING moves.
        balancerVault.setNextBptOutOverride(minOut - 1);
        vm.prank(MARKET_OPS_ADMIN);
        kernel.reinvestLiquidityPremium(type(uint256).max);
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, idle, "under the gate: idle pile untouched");
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), ltOwnedBefore, "under the gate: no BPT credited");

        // Side 2: exactly the gate => the entire pile deploys and exactly minOut BPT is credited.
        balancerVault.setNextBptOutOverride(minOut);
        vm.prank(MARKET_OPS_ADMIN);
        kernel.reinvestLiquidityPremium(type(uint256).max);
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, 0, "at the gate: entire idle pile deployed");
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), ltOwnedBefore + minOut, "at the gate: exactly minOut BPT credited");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // B8 — multi-asset preview parity: exact at zero venue fee, fee-bounded under one
    // ═══════════════════════════════════════════════════════════════════════════

    /// Zero venue fee => EXACT preview parity. A fair (fee-less) add leaves TVL-per-BPT unchanged, so the executed
    /// path's post-add mark equals the preview's discarded-quote pre-add mark and the share math coincides to the wei.
    function test_multiAssetDepositPreviewParity_exact_zeroVenueFee() external {
        (uint256 previewShares, uint256 mintedShares) = _previewThenExecuteMultiAssetDeposit(5e18, 5e6);
        assertEq(mintedShares, previewShares, "zero venue fee: multi-asset deposit preview == execution, same block");
        assertGt(mintedShares, 0, "arrange: the deposit must be non-degenerate");
    }

    /// With a venue fee the preview is a compliant LOWER bound (EIP-4626 previewDeposit MUST NOT overestimate):
    /// execution marks the fresh BPT AFTER the add — when the depositor's own fee has already accrued to the pool's
    /// TVL-per-BPT — while the preview's vault.quote discards that post-add uplift. The gap is bounded by the fee
    /// itself: the depositor recaptures at most their own 30 bps, so preview <= minted <= ceil(preview * (1 + fee)).
    function test_multiAssetDepositPreview_lowerBoundsExecution_withVenueFee() external {
        balancerVault.setUnbalancedFeeBps(30);
        (uint256 previewShares, uint256 mintedShares) = _previewThenExecuteMultiAssetDeposit(5e18, 5e6);

        assertGe(mintedShares, previewShares, "preview never overestimates the minted shares");
        assertLe(
            mintedShares,
            Math.mulDiv(previewShares, WAD + 0.003e18, WAD, Math.Rounding.Ceil),
            "the preview gap is bounded by the 30 bps venue fee the depositor recaptures"
        );
    }

    /// previewRedeemMultiAsset == executed redeemMultiAsset (ST claims + quote out), same block.
    function test_multiAssetRedeemPreviewParity() external {
        _seedMarket(100e18, 50e18);
        _seedLT(10e18, 0, 10e6); // quote-only LT depth on top of the auto-seed

        uint256 ltShares = liquidityTranche.balanceOf(LT_PROVIDER) / 2;
        assertGt(ltShares, 0, "arrange: LT_PROVIDER holds shares to redeem");

        vm.startPrank(LT_PROVIDER);
        (AssetClaims memory previewClaims, uint256 previewQuote) = liquidityTranche.previewRedeemMultiAsset(ltShares);
        (AssetClaims memory claims, uint256 quoteOut) = liquidityTranche.redeemMultiAsset(ltShares, 0, 0, LT_PROVIDER, LT_PROVIDER);
        vm.stopPrank();

        assertEq(quoteOut, previewQuote, "quote leg preview == execution");
        assertEq(keccak256(abi.encode(claims)), keccak256(abi.encode(previewClaims)), "ST claims preview == execution");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Seeds the market, refreshes the transient ST_SHARE_RATE cache (the seeding syncs above ran inside THIS
    ///      test transaction and the last pre-op cache write predates the senior supply, so the venue would price the
    ///      ST leg at the 1-wei floor — a state production never sees, since every user interaction is its own
    ///      transaction and syncs pre-op), then previews and executes the same multi-asset deposit in one block.
    function _previewThenExecuteMultiAssetDeposit(uint256 _stLeg, uint256 _quoteLeg) internal returns (uint256 previewShares, uint256 mintedShares) {
        _seedMarket(100e18, 50e18);
        vm.prank(SYNC_OPERATOR);
        kernel.syncTrancheAccounting();

        stJtVault.mintShares(LT_PROVIDER, _stLeg);
        quoteToken.mint(LT_PROVIDER, _quoteLeg);

        vm.startPrank(LT_PROVIDER);
        stJtVault.approve(address(liquidityTranche), _stLeg);
        quoteToken.approve(address(liquidityTranche), _quoteLeg);
        previewShares = liquidityTranche.previewDepositMultiAsset(_stLeg, _quoteLeg);
        mintedShares = liquidityTranche.depositMultiAsset(_stLeg, _quoteLeg, 0, LT_PROVIDER);
        vm.stopPrank();
    }

    /// @dev Stages an idle premium pile: arm venue slippage so the sync's auto-reinvest defers, accrue senior gain
    ///      across a premium window, sync, then disarm. Returns the staged idle ST shares (must be > 0).
    function _stageIdlePremium() internal returns (uint256 idle) {
        _seedMarket(100e18, 50e18);

        // First sync initializes the premium accrual clock.
        vm.prank(SYNC_OPERATOR);
        kernel.syncTrancheAccounting();

        // Arm the 50% unbalanced haircut so the gated reinvest deterministically fails and the premium stays idle.
        setVenueSlippageMode(true);

        // Accrue senior gain across a real time window, then sync: the LT premium mints as idle ST shares.
        _warpAndRefreshFeed(1 days);
        applySTPnL(1000); // +10%
        vm.prank(SYNC_OPERATOR);
        kernel.syncTrancheAccounting();

        idle = kernel.getState().ltOwnedSeniorTrancheShares;
        assertGt(idle, 0, "arrange: the premium must be staged idle (venue slippage armed)");

        // Disarm so the boundary tests control the venue's mint exactly via the one-shot override.
        setVenueSlippageMode(false);
    }

    /// @dev A minimal swap-params carrier for onBeforeSwap; only `router` is read by the hook.
    function _swapParams(address _router) internal pure returns (PoolSwapParams memory) {
        return PoolSwapParams({
            kind: SwapKind.EXACT_IN, amountGivenScaled18: 0, balancesScaled18: new uint256[](2), indexIn: 0, indexOut: 1, router: _router, userData: ""
        });
    }
}
