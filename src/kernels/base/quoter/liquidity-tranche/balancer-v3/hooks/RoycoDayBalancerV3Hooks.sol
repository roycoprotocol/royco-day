// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { IHooks } from "../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IHooks.sol";
import {
    AddLiquidityKind,
    HookFlags,
    LiquidityManagement,
    PoolSwapParams,
    RemoveLiquidityKind,
    TokenConfig
} from "../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { BalancerPoolToken } from "../../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { BaseHooks } from "../../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BaseHooks.sol";
import { VaultGuard } from "../../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/VaultGuard.sol";
import { RoycoBase } from "../../../../../../base/RoycoBase.sol";
import { IRoycoDayKernel } from "../../../../../../interfaces/IRoycoDayKernel.sol";

/**
 * @title RoycoDayBalancerV3Hooks
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Balancer V3 hook contract that synchronizes the kernel's tranche accounting before each operation on a Day market's liquidity tranche pool
 * @notice Externally-initiated operations (swaps and third-party liquidity provision) reconcile unrealized PnL on the kernel before they are fulfilled
 */
contract RoycoDayBalancerV3Hooks is RoycoBase, BaseHooks, VaultGuard {
    /// @notice The Royco Day kernel this hook contract bridges Balancer V3 pool operations into
    address public immutable ROYCO_DAY_KERNEL;

    /// @notice The liquidity tranche's Balancer V3 pool (the BPT) that this hook contract guards
    address public immutable LIQUIDITY_TRANCHE_BALANCER_V3_POOL;

    /// @notice Thrown when the pool invoking a hook isn't this market's liquidity tranche pool
    error ONLY_LIQUIDITY_TRANCHE_BALANCER_V3_POOL();

    /// @dev Ensures that the pool invoking a hook is this market's liquidity tranche pool
    /// @param _pool The pool invoking the hook
    modifier onlyLiquidityTrancheBalancerV3Pool(address _pool) {
        require(_pool == LIQUIDITY_TRANCHE_BALANCER_V3_POOL, ONLY_LIQUIDITY_TRANCHE_BALANCER_V3_POOL());
        _;
    }

    // =============================
    // Construction and Initialization Functions
    // =============================

    /**
     * @notice Constructs the Royco Day Balancer V3 hooks contract
     * @dev Pins the kernel and derives the liquidity tranche's Balancer V3 pool (the kernel's `LT_ASSET`, the BPT) and, through the pool, the
     *      Balancer V3 Vault it is registered with, so the hook's Vault always matches the guarded pool's Vault
     * @param _roycoKernel The Royco Day kernel this hook contract bridges pool operations into
     */
    constructor(address _roycoKernel)
        VaultGuard(BalancerPoolToken((LIQUIDITY_TRANCHE_BALANCER_V3_POOL = IRoycoDayKernel(_roycoKernel).LT_ASSET())).getVault())
    {
        ROYCO_DAY_KERNEL = _roycoKernel;
    }

    /// @notice Initializes the Royco Day Balancer V3 hooks contract
    /// @param _initialAuthority The initial authority for the contract
    function initialize(address _initialAuthority) external virtual initializer {
        __RoycoBase_init(_initialAuthority);
    }

    // =============================
    // Balancer V3 Pool Hook Callbacks
    // =============================

    /**
     * @inheritdoc IHooks
     * @dev Returns false so a pool cannot be registered directly against this implementation
     *      The kernel, pool, and hook form a circular
     *      construction dependency (the hook derives the pool from the kernel, the kernel from the pool), so registration is performed against
     *      a stand-in implementation that returns true and the same `getHookFlags`, after which the proxy is upgraded to this implementation
     */
    function onRegister(address, address, TokenConfig[] memory, LiquidityManagement calldata) public pure override(BaseHooks) returns (bool) {
        return false;
    }

    /// @inheritdoc IHooks
    /// @dev Skips the sync when invoked by the Royco Day kernel: the outer LT deposit flow (multi-asset join and premium add) already brackets the add with its own pre/post syncs
    function onBeforeAddLiquidity(
        address _router,
        address _pool,
        AddLiquidityKind,
        uint256[] memory,
        uint256,
        uint256[] memory,
        bytes memory
    )
        public
        override(BaseHooks)
        onlyVault
        onlyLiquidityTrancheBalancerV3Pool(_pool)
        returns (bool)
    {
        return (_router == ROYCO_DAY_KERNEL || _preLiquidityOperationSyncTrancheAccounting());
    }

    /// @inheritdoc IHooks
    /// @dev Skips the sync when invoked by the Royco Day kernel: the outer LT redeem flow already brackets the unwrap with its own pre/post syncs
    function onBeforeRemoveLiquidity(
        address _router,
        address _pool,
        RemoveLiquidityKind,
        uint256,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    )
        public
        override(BaseHooks)
        onlyVault
        onlyLiquidityTrancheBalancerV3Pool(_pool)
        returns (bool)
    {
        return (_router == ROYCO_DAY_KERNEL || _preLiquidityOperationSyncTrancheAccounting());
    }

    /// @inheritdoc IHooks
    function onBeforeSwap(PoolSwapParams calldata, address _pool)
        public
        override(BaseHooks)
        onlyVault
        onlyLiquidityTrancheBalancerV3Pool(_pool)
        returns (bool)
    {
        return _preLiquidityOperationSyncTrancheAccounting();
    }

    /// @inheritdoc IHooks
    /// @dev All liquidity operations execute a PNL accounting sync to ensure that accounting is fresh before the operation
    function getHookFlags() public view virtual override(BaseHooks) returns (HookFlags memory) {
        return HookFlags({
            enableHookAdjustedAmounts: false,
            shouldCallBeforeInitialize: false,
            shouldCallAfterInitialize: false,
            shouldCallComputeDynamicSwapFee: false,
            shouldCallBeforeSwap: true,
            shouldCallAfterSwap: false,
            shouldCallBeforeAddLiquidity: true,
            shouldCallAfterAddLiquidity: false,
            shouldCallBeforeRemoveLiquidity: true,
            shouldCallAfterRemoveLiquidity: false
        });
    }

    // =============================
    // Internal Tranche Accounting Synchronization Helpers
    // =============================

    /**
     * @notice Routes a pre-operation tranche accounting sync into the kernel
     * @dev Intended to be invoked from every externally-initiated `onBefore*` hook (add/remove liquidity, swap) so the
     *      kernel captures any oracle drift on the senior side before the operation mutates the pool's composition
     * @dev Requires this hook contract to hold the SYNCER role on the kernel
     * @dev Reverts if this hook contract is paused
     * @return synced Always true on success, letting callers forward the result directly as the hook's required `bool` return
     */
    function _preLiquidityOperationSyncTrancheAccounting() internal whenNotPaused returns (bool synced) {
        IRoycoDayKernel(ROYCO_DAY_KERNEL).syncTrancheAccounting();
        return true;
    }
}
