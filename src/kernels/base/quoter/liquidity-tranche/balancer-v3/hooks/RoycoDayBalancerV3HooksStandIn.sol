// SPDX-License-Identifier: GPL-3.0-or-later
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
 *      `getHookFlags` AT REGISTRATION TIME, so this stand-in advertises the EXACT SAME flags as the real hook
 *      After the kernel is deployed, the deploy template upgrades this proxy to the real `RoycoDayBalancerV3Hooks`
 *      implementation, and the frozen flags then match the real hook's callbacks
 *
 *      The proxy against this stand-in is deployed BEFORE the market's wiring transaction (so the pool can be created
 *      script-side) and therefore persists across transactions, so `_authorizeUpgrade` is restricted to the deploying
 *      template (pinned at construction) rather than left open: the template is the sole party allowed to upgrade the
 *      proxy to the real hook, closing the cross-transaction window an open upgrade would expose
 */
contract RoycoDayBalancerV3HooksStandIn is BaseHooks, UUPSUpgradeable {
    /// @notice Thrown when a party other than the deploying template attempts to upgrade the stand-in proxy
    error ONLY_TEMPLATE();

    /// @notice The deployment template that instantiated this stand-in, the only party allowed to upgrade its proxy
    /// @dev Pinned to the constructing template (the stand-in impl is deployed inside the template's constructor)
    address public immutable TEMPLATE;

    constructor() {
        TEMPLATE = msg.sender;
    }

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

    /// @dev Restricted to the deploying template, see contract-level notice: the proxy persists across transactions
    ///      before the wiring tx upgrades it to the real hook, so only the template may perform that upgrade
    function _authorizeUpgrade(address) internal view override(UUPSUpgradeable) {
        require(msg.sender == TEMPLATE, ONLY_TEMPLATE());
    }

    /// noop fallback to prevent the proxy from reverting if it receives a call
    fallback() external { }
}
