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
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { SYNC_ROLE } from "../../../src/factory/RolesConfiguration.sol";
import {
    RoycoDayBalancerV3Hooks
} from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/RoycoDayBalancerV3Hooks.sol";
import {
    RoycoDayBalancerV3HooksStandIn
} from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/RoycoDayBalancerV3HooksStandIn.sol";
import { defaultParams } from "../../base/fixtures/MarketParams.sol";
import { cellA } from "../../base/fixtures/TokenConfigs.sol";
import { TrancheFixture } from "../../base/fixtures/TrancheFixture.sol";

/**
 * @title BalancerHooksSyncTest
 * @notice Exercises the pool hook that syncs the kernel's accounting before every externally-initiated pool
 *         operation: the kernel-router short circuit, the external-router sync path on all three callbacks, the
 *         pool and vault caller gates, the registration-refusal design, and the frozen flag set
 * @dev The hook is the production guarantee that a third-party swap or join can never trade against a stale
 *      senior-leg rate: if these dispatch rules drift, external pool flow executes on pre-sync marks
 */
contract BalancerHooksSyncTest is TrancheFixture {
    /// @dev The real hook behind a proxy, wired to the fixture kernel and granted the sync role
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
        // The hook syncs through the kernel's restricted sync entrypoint, so it holds the sync role like production wiring
        accessManager.grantRole(SYNC_ROLE, address(hooks), 0);
        EXTERNAL_ROUTER = makeAddr("EXTERNAL_ROUTER");
    }

    /// @dev Builds an arbitrary swap-params packet, the hook ignores every field but the pool
    function _swapParams() internal view returns (PoolSwapParams memory params) {
        params.kind = SwapKind.EXACT_IN;
        params.amountGivenScaled18 = 1e18;
        params.balancesScaled18 = new uint256[](2);
        params.indexIn = stPoolTokenIndex;
        params.indexOut = 1 - stPoolTokenIndex;
        params.router = EXTERNAL_ROUTER;
    }

    // =============================
    // Callback dispatch
    // =============================

    /// @notice Constructor wiring: the hook pins the kernel and derives the guarded pool from the kernel's LT asset
    function test_Construction_derivesPoolFromKernel() public view {
        assertEq(hooks.ROYCO_DAY_KERNEL(), address(kernel), "the hook must pin the kernel it bridges into");
        assertEq(hooks.LIQUIDITY_TRANCHE_BALANCER_V3_POOL(), address(bpt), "the hook must guard the kernel's LT pool");
    }

    /// @notice An external swap on the LT pool syncs the kernel's accounting before it is allowed through
    function test_OnBeforeSwap_externalSwapSyncsKernelAccounting() public {
        // A +100 bps senior move is pending: the hook's pre-swap sync must commit it before the swap prices.
        // On this unseeded market the sync commits zero NAVs, so the pin is the dispatch itself: the hook reaches
        // the kernel's restricted sync through its own role grant and then allows the swap
        applySTPnL(100);
        vm.prank(address(balancerVault));
        assertTrue(hooks.onBeforeSwap(_swapParams(), address(bpt)), "the pre-swap hook must allow the swap after syncing");
    }

    /// @notice A kernel-routed add short-circuits (the kernel already brackets it with syncs) while an external add syncs
    function test_OnBeforeAddLiquidity_kernelRouterShortCircuitsAndExternalSyncs() public {
        uint256[] memory amounts = new uint256[](2);
        vm.startPrank(address(balancerVault));
        assertTrue(
            hooks.onBeforeAddLiquidity(address(kernel), address(bpt), AddLiquidityKind.UNBALANCED, amounts, 0, amounts, ""),
            "a kernel-routed add must pass without a second sync"
        );
        assertTrue(
            hooks.onBeforeAddLiquidity(EXTERNAL_ROUTER, address(bpt), AddLiquidityKind.UNBALANCED, amounts, 0, amounts, ""),
            "an externally-routed add must pass after syncing"
        );
        vm.stopPrank();
    }

    /// @notice A kernel-routed removal short-circuits while an external removal syncs
    function test_OnBeforeRemoveLiquidity_kernelRouterShortCircuitsAndExternalSyncs() public {
        uint256[] memory amounts = new uint256[](2);
        vm.startPrank(address(balancerVault));
        assertTrue(
            hooks.onBeforeRemoveLiquidity(address(kernel), address(bpt), RemoveLiquidityKind.PROPORTIONAL, 0, amounts, amounts, ""),
            "a kernel-routed removal must pass without a second sync"
        );
        assertTrue(
            hooks.onBeforeRemoveLiquidity(EXTERNAL_ROUTER, address(bpt), RemoveLiquidityKind.PROPORTIONAL, 0, amounts, amounts, ""),
            "an externally-routed removal must pass after syncing"
        );
        vm.stopPrank();
    }

    // =============================
    // Caller gates
    // =============================

    /// @notice A hook invocation for any pool other than this market's LT pool is rejected
    function test_RevertIf_HookInvokedForForeignPool() public {
        address foreignPool = makeAddr("FOREIGN_POOL");
        vm.prank(address(balancerVault));
        vm.expectRevert(RoycoDayBalancerV3Hooks.ONLY_LIQUIDITY_TRANCHE_BALANCER_V3_POOL.selector);
        hooks.onBeforeSwap(_swapParams(), foreignPool);
    }

    /// @notice A hook invocation from anyone but the Balancer vault is rejected
    function test_RevertIf_HookInvokedByNonVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        hooks.onBeforeSwap(_swapParams(), address(bpt));
    }

    /// @notice While the hook contract is paused, external pool operations are halted at the pre-operation sync
    function test_RevertIf_ExternalOperationWhileHookPaused() public {
        // Unconfigured selectors on the access manager default to the admin role, which this test contract holds
        hooks.pause();
        vm.prank(address(balancerVault));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        hooks.onBeforeSwap(_swapParams(), address(bpt));
        // The kernel-routed short circuit does not touch the paused sync helper, so kernel flow stays live
        uint256[] memory amounts = new uint256[](2);
        vm.prank(address(balancerVault));
        assertTrue(
            hooks.onBeforeAddLiquidity(address(kernel), address(bpt), AddLiquidityKind.UNBALANCED, amounts, 0, amounts, ""),
            "the kernel-routed path must stay live while the hook is paused"
        );
    }

    // =============================
    // Registration design
    // =============================

    /**
     * @notice The real hook refuses direct pool registration while the stand-in accepts it with identical frozen flags
     * @dev The vault freezes the callback set from getHookFlags at registration, so the stand-in must advertise
     *      byte-identical flags or the real hook's callbacks would never fire after the upgrade
     */
    function test_Registration_realHookRefusesAndStandInAcceptsWithIdenticalFlags() public {
        RoycoDayBalancerV3HooksStandIn standIn = new RoycoDayBalancerV3HooksStandIn();
        TokenConfig[] memory emptyTokenConfig;
        LiquidityManagement memory management;
        assertFalse(hooks.onRegister(address(this), address(bpt), emptyTokenConfig, management), "the real hook must refuse direct registration");
        assertTrue(standIn.onRegister(address(this), address(bpt), emptyTokenConfig, management), "the stand-in must accept registration");

        HookFlags memory realFlags = hooks.getHookFlags();
        HookFlags memory standInFlags = standIn.getHookFlags();
        assertEq(keccak256(abi.encode(realFlags)), keccak256(abi.encode(standInFlags)), "the stand-in's frozen flags must be byte-identical to the real hook's");
        // The three pre-operation callbacks are the hook's whole job, they must be armed
        assertTrue(realFlags.shouldCallBeforeSwap && realFlags.shouldCallBeforeAddLiquidity && realFlags.shouldCallBeforeRemoveLiquidity, "all three before-operation callbacks must be armed");
    }
}
