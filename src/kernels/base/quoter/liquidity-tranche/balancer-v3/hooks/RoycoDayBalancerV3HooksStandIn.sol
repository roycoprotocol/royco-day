// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { HookFlags, LiquidityManagement, TokenConfig } from "../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { BaseHooks } from "../../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BaseHooks.sol";
import { UUPSUpgradeable } from "../../../../../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title RoycoDayBalancerV3HooksStandIn
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Registration-time stand-in for `RoycoDayBalancerV3Hooks`, deployed behind a proxy and used as the pool's hook
 *         ONLY to get the pool registered with the Balancer V3 Vault
 *
 * @dev The real hook, kernel, and pool form a circular construction dependency (the hook derives the pool from the
 *      kernel, the kernel derives the quote asset from the pool, and the pool is created before the kernel exists), and
 *      the real hook's `onRegister` returns `false` so it cannot be registered directly
 *      The Vault calls `onRegister` (which this returns `true` for) and freezes the pool's callback set from
 *      `getHookFlags` AT REGISTRATION TIME — so this stand-in advertises the EXACT SAME flags as the real hook
 *      After the kernel is deployed, the deploy template upgrades this proxy to the real `RoycoDayBalancerV3Hooks`
 *      implementation, and the frozen flags then match the real hook's callbacks
 *      `_authorizeUpgrade` is intentionally open because the proxy is upgraded to the real,
 *      access-controlled hook within the same deployment transaction — the open window never survives the deploy
 */
contract RoycoDayBalancerV3HooksStandIn is BaseHooks, UUPSUpgradeable {
    /// @inheritdoc BaseHooks
    /// @dev No-op: returns true so the Vault accepts the pool registration against this stand-in
    function onRegister(address, address, TokenConfig[] memory, LiquidityManagement calldata) public pure override(BaseHooks) returns (bool) {
        return true;
    }

    /**
     * @inheritdoc BaseHooks
     * @dev MUST stay byte-for-byte identical to `RoycoDayBalancerV3Hooks.getHookFlags`: the Vault freezes these at
     *      registration and the real hook's callbacks only fire for flags captured here
     */
    function getHookFlags() public pure override(BaseHooks) returns (HookFlags memory) {
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

    /// @dev Open by design — see contract-level notice: the proxy is upgraded to the real hook during the deploy tx
    function _authorizeUpgrade(address) internal pure override(UUPSUpgradeable) { }

    /// noop fallback to prevent the proxy from reverting if it receives a call
    fallback() external { }
}
