// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVaultErrors } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";
import {
    AddLiquidityKind,
    HookFlags,
    LiquidityManagement,
    PoolSwapParams,
    RemoveLiquidityKind,
    SwapKind,
    TokenConfig
} from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SYNC_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoDayBalancerV3Hooks } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/hooks/RoycoDayBalancerV3Hooks.sol";
import { RoycoDayBalancerV3HooksStandIn } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/hooks/RoycoDayBalancerV3HooksStandIn.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_SyncDispatch_BalancerV3Hooks
 * @notice Exercises the production pool hook that syncs the kernel's tranche accounting before every
 *         externally-initiated pool operation: the sync path on all three callbacks, the kernel-router skip on the
 *         liquidity callbacks (and its deliberate absence on swaps), the pool and vault caller gates, pause, the
 *         SYNC_ROLE liveness dependency, and the registration-refusal design with its frozen flag set
 * @dev The hook is the production guarantee that a third-party swap or join can never trade against a stale
 *      senior-leg rate: if these dispatch rules drift, external pool flow executes on pre-sync marks. The hooks
 *      contract does not exist in the fixture's mock market, so setUp deploys the REAL RoycoDayBalancerV3Hooks
 *      proxy against the fixture's kernel and mock vault, the exact production wiring minus Balancer's dispatch,
 *      which the tests stand in for by pranking the vault
 */
contract Test_SyncDispatch_BalancerV3Hooks is DayMarketTestBase {
    /// @dev The real hook behind a proxy, wired to the fixture kernel and granted the sync role like production
    RoycoDayBalancerV3Hooks internal hooks;

    /// @dev An external router address standing in for any non-kernel pool caller
    address internal EXTERNAL_ROUTER;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        hooks = RoycoDayBalancerV3Hooks(
            address(
                new ERC1967Proxy(
                    address(new RoycoDayBalancerV3Hooks(address(kernel))), abi.encodeCall(RoycoDayBalancerV3Hooks.initialize, (address(accessManager)))
                )
            )
        );
        // The hook syncs through the kernel's restricted sync entrypoint, so it holds the sync role like production
        // wiring (the ungranted case is the liveness test below, which deploys its own ungranted hook)
        accessManager.grantRole(SYNC_ROLE, address(hooks), 0);
        EXTERNAL_ROUTER = makeAddr("EXTERNAL_ROUTER");
    }

    // =============================
    // Construction wiring
    // =============================

    /// @notice Constructor wiring: the hook pins the kernel and derives the guarded pool from the kernel's LT asset
    function test_Construction_DerivesPoolFromKernel() public view {
        assertEq(hooks.ROYCO_DAY_KERNEL(), address(kernel), "the hook must pin the kernel it bridges into");
        assertEq(hooks.LIQUIDITY_TRANCHE_BALANCER_V3_POOL(), address(bpt), "the hook must guard the kernel's LT pool");
    }

    // =============================
    // Callback dispatch, external routers sync
    // =============================

    /**
     * @notice An externally-routed swap syncs the kernel BEFORE the swap, so unrealized collateral PnL lands in
     *         the committed checkpoint and the swap prices against a fresh senior-leg rate
     * @dev Expected committed collateral NAV is hand-derived: totalCollateralAssets x the 1.1 vault rate x the 1.0 feed, floored
     */
    function test_OnBeforeSwap_ExternalSwapCommitsPendingCollateralPnL() public {
        _seedMarket(100e18, 50e18);
        applySTPnL(1000); // +10%: vault rate 1.0 -> 1.1

        uint256 ownedAssets = toUint256(kernel.getState().totalCollateralAssets);
        uint256 expectedCollateralNAV = Math.mulDiv(ownedAssets, 1.1e18, 1e18, Math.Rounding.Floor);
        assertTrue(toUint256(accountant.getState().lastCollateralNAV) != expectedCollateralNAV, "arrange: the PnL must be uncommitted");

        vm.prank(address(balancerVault));
        bool ok = hooks.onBeforeSwap(_swapParams(EXTERNAL_ROUTER), address(bpt));

        assertTrue(ok, "the pre-swap hook must allow the swap after syncing");
        assertEq(toUint256(accountant.getState().lastCollateralNAV), expectedCollateralNAV, "the sync must commit the collateral PnL before the swap");
    }

    /**
     * @notice A kernel-routed swap ALSO syncs: unlike the liquidity callbacks, onBeforeSwap has no router skip
     * @dev Attacker relevance: if a kernel-router exemption existed on swaps, anyone who could make the router
     *      field read as the kernel would trade against the stale pre-sync rate. This pins that no such path exists
     */
    function test_OnBeforeSwap_KernelRouterStillSyncs() public {
        _seedMarket(100e18, 50e18);
        applySTPnL(1000); // +10%

        uint256 ownedAssets = toUint256(kernel.getState().totalCollateralAssets);
        uint256 expectedCollateralNAV = Math.mulDiv(ownedAssets, 1.1e18, 1e18, Math.Rounding.Floor);

        vm.prank(address(balancerVault));
        assertTrue(hooks.onBeforeSwap(_swapParams(address(kernel)), address(bpt)), "the kernel-routed swap must still pass");
        assertEq(toUint256(accountant.getState().lastCollateralNAV), expectedCollateralNAV, "a kernel-routed swap must sync, swaps have no router skip");
    }

    /// @notice Externally-routed add and remove liquidity both sync before the operation, same path as the swap hook
    function test_OnBeforeAddAndRemoveLiquidity_ExternalRouterSyncs() public {
        _seedMarket(100e18, 50e18);
        uint256 ownedAssets = toUint256(kernel.getState().totalCollateralAssets);

        applySTPnL(500); // +5%: vault rate 1.0 -> 1.05
        vm.prank(address(balancerVault));
        assertTrue(
            hooks.onBeforeAddLiquidity(EXTERNAL_ROUTER, address(bpt), AddLiquidityKind.UNBALANCED, new uint256[](2), 0, new uint256[](2), ""),
            "the externally-routed add must pass after syncing"
        );
        assertEq(
            toUint256(accountant.getState().lastCollateralNAV),
            Math.mulDiv(ownedAssets, 1.05e18, 1e18, Math.Rounding.Floor),
            "the add hook must commit the +5% collateral PnL"
        );

        applySTPnL(500); // a further +5% on the new rate: 1.05 x 1.05 = 1.1025
        vm.prank(address(balancerVault));
        assertTrue(
            hooks.onBeforeRemoveLiquidity(EXTERNAL_ROUTER, address(bpt), RemoveLiquidityKind.PROPORTIONAL, 0, new uint256[](2), new uint256[](2), ""),
            "the externally-routed removal must pass after syncing"
        );
        assertEq(
            toUint256(accountant.getState().lastCollateralNAV),
            Math.mulDiv(ownedAssets, 1.1025e18, 1e18, Math.Rounding.Floor),
            "the remove hook must commit the compounded collateral PnL"
        );
    }

    /**
     * @notice Kernel-routed add and remove liquidity SKIP the hook sync: the outer LT flow already brackets the
     *         operation with its own pre/post syncs, so uncommitted PnL must remain uncommitted across both callbacks
     */
    function test_OnBeforeAddAndRemoveLiquidity_KernelRouterSkipsSync() public {
        _seedMarket(100e18, 50e18);
        applySTPnL(1000);
        uint256 committedBefore = toUint256(accountant.getState().lastCollateralNAV);

        vm.startPrank(address(balancerVault));
        assertTrue(
            hooks.onBeforeAddLiquidity(address(kernel), address(bpt), AddLiquidityKind.UNBALANCED, new uint256[](2), 0, new uint256[](2), ""),
            "the kernel-routed add must pass without a second sync"
        );
        assertEq(toUint256(accountant.getState().lastCollateralNAV), committedBefore, "the committed checkpoint must be untouched by the kernel-routed add");
        assertTrue(
            hooks.onBeforeRemoveLiquidity(address(kernel), address(bpt), RemoveLiquidityKind.PROPORTIONAL, 0, new uint256[](2), new uint256[](2), ""),
            "the kernel-routed removal must pass without a second sync"
        );
        assertEq(toUint256(accountant.getState().lastCollateralNAV), committedBefore, "the committed checkpoint must be untouched by the kernel-routed removal");
        vm.stopPrank();
    }

    // =============================
    // Caller gates
    // =============================

    /// @notice A hook invocation for any pool other than this market's LT pool is rejected
    function test_RevertIf_HookInvokedForForeignPool() public {
        vm.prank(address(balancerVault));
        vm.expectRevert(RoycoDayBalancerV3Hooks.ONLY_LIQUIDITY_TRANCHE_BALANCER_V3_POOL.selector);
        hooks.onBeforeSwap(_swapParams(EXTERNAL_ROUTER), makeAddr("FOREIGN_POOL"));
    }

    /// @notice A hook invocation from anyone but the Balancer vault is rejected, no one can forge a pre-operation frame
    function test_RevertIf_HookInvokedByNonVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        hooks.onBeforeSwap(_swapParams(EXTERNAL_ROUTER), address(bpt));
    }

    /**
     * @notice While the hook contract is paused, external pool operations are halted at the pre-operation sync,
     *         but the kernel-routed skip never touches the paused sync helper so kernel flow stays live
     */
    function test_RevertIf_ExternalOperationWhileHookPaused() public {
        // Unconfigured selectors on the access manager default to the admin role, which this test contract holds
        hooks.pause();
        vm.prank(address(balancerVault));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        hooks.onBeforeSwap(_swapParams(EXTERNAL_ROUTER), address(bpt));

        vm.prank(address(balancerVault));
        assertTrue(
            hooks.onBeforeAddLiquidity(address(kernel), address(bpt), AddLiquidityKind.UNBALANCED, new uint256[](2), 0, new uint256[](2), ""),
            "the kernel-routed path must stay live while the hook is paused"
        );
    }

    /**
     * @notice While the hook contract is paused, externally-routed add and remove liquidity are both halted at the
     *         pre-operation sync, the same EnforcedPause gate that blocks external swaps
     */
    function test_RevertIf_ExternalAddOrRemoveLiquidityWhileHookPaused() public {
        hooks.pause();

        vm.prank(address(balancerVault));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        hooks.onBeforeAddLiquidity(EXTERNAL_ROUTER, address(bpt), AddLiquidityKind.UNBALANCED, new uint256[](2), 0, new uint256[](2), "");

        vm.prank(address(balancerVault));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        hooks.onBeforeRemoveLiquidity(EXTERNAL_ROUTER, address(bpt), RemoveLiquidityKind.PROPORTIONAL, 0, new uint256[](2), new uint256[](2), "");
    }

    /**
     * @notice Unpausing the hook restores externally-routed add and remove liquidity, and the restored path still
     *         syncs, committing pending collateral PnL before each operation rather than passing vacuously
     */
    function test_ExternalAddAndRemoveLiquidity_RecoverAfterUnpause() public {
        _seedMarket(100e18, 50e18);
        uint256 ownedAssets = toUint256(kernel.getState().totalCollateralAssets);
        hooks.pause();
        hooks.unpause();

        applySTPnL(500); // +5%: vault rate 1.0 -> 1.05
        vm.prank(address(balancerVault));
        assertTrue(
            hooks.onBeforeAddLiquidity(EXTERNAL_ROUTER, address(bpt), AddLiquidityKind.UNBALANCED, new uint256[](2), 0, new uint256[](2), ""),
            "the externally-routed add must pass after the unpause"
        );
        assertEq(
            toUint256(accountant.getState().lastCollateralNAV),
            Math.mulDiv(ownedAssets, 1.05e18, 1e18, Math.Rounding.Floor),
            "the recovered add hook must still commit the pending collateral PnL"
        );

        applySTPnL(500); // a further +5% on the new rate: 1.05 x 1.05 = 1.1025
        vm.prank(address(balancerVault));
        assertTrue(
            hooks.onBeforeRemoveLiquidity(EXTERNAL_ROUTER, address(bpt), RemoveLiquidityKind.PROPORTIONAL, 0, new uint256[](2), new uint256[](2), ""),
            "the externally-routed removal must pass after the unpause"
        );
        assertEq(
            toUint256(accountant.getState().lastCollateralNAV),
            Math.mulDiv(ownedAssets, 1.1025e18, 1e18, Math.Rounding.Floor),
            "the recovered remove hook must still commit the compounded collateral PnL"
        );
    }

    /**
     * @notice A hook deployed WITHOUT the sync role makes every external pool operation revert with the hook's own
     *         AccessManagedUnauthorized, so a deploy-time grant omission produces an operationally dead pool
     * @dev This pins the liveness dependency from the failure side: the pool's external flow depends on one role
     *      grant that nothing else validates at deployment
     */
    function test_RevertIf_HookLacksSyncRole() public {
        _seedMarket(100e18, 50e18);
        RoycoDayBalancerV3Hooks ungranted = RoycoDayBalancerV3Hooks(
            address(
                new ERC1967Proxy(
                    address(new RoycoDayBalancerV3Hooks(address(kernel))), abi.encodeCall(RoycoDayBalancerV3Hooks.initialize, (address(accessManager)))
                )
            )
        );

        vm.prank(address(balancerVault));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(ungranted)));
        ungranted.onBeforeSwap(_swapParams(EXTERNAL_ROUTER), address(bpt));
    }

    // =============================
    // Registration design
    // =============================

    /**
     * @notice The real hook refuses direct pool registration while the stand-in accepts it with identical frozen flags
     * @dev The vault freezes the callback set from getHookFlags at registration, so the stand-in must advertise
     *      byte-identical flags or the real hook's callbacks would silently never fire after the upgrade, the one
     *      non-reverting mis-wire in the deployment design
     */
    function test_Registration_RealHookRefusesAndStandInAcceptsWithIdenticalFlags() public {
        RoycoDayBalancerV3HooksStandIn standIn = new RoycoDayBalancerV3HooksStandIn();
        TokenConfig[] memory emptyTokenConfig;
        LiquidityManagement memory management;
        assertFalse(hooks.onRegister(address(this), address(bpt), emptyTokenConfig, management), "the real hook must refuse direct registration");
        assertTrue(standIn.onRegister(address(this), address(bpt), emptyTokenConfig, management), "the stand-in must accept registration");

        HookFlags memory realFlags = hooks.getHookFlags();
        HookFlags memory standInFlags = standIn.getHookFlags();
        assertEq(keccak256(abi.encode(realFlags)), keccak256(abi.encode(standInFlags)), "the stand-in's frozen flags must be byte-identical to the real hook's");
        // The three pre-operation callbacks are the hook's whole job, they must be armed
        assertTrue(
            realFlags.shouldCallBeforeSwap && realFlags.shouldCallBeforeAddLiquidity && realFlags.shouldCallBeforeRemoveLiquidity,
            "all three before-operation callbacks must be armed"
        );
    }

    // =============================
    // Helpers
    // =============================

    /// @dev Builds a swap-params packet for the specified router, the hook reads only the router and the pool
    function _swapParams(address _router) internal view returns (PoolSwapParams memory params) {
        params.kind = SwapKind.EXACT_IN;
        params.amountGivenScaled18 = 1e18;
        params.balancesScaled18 = new uint256[](2);
        params.indexIn = stPoolTokenIndex;
        params.indexOut = 1 - stPoolTokenIndex;
        params.router = _router;
    }
}
