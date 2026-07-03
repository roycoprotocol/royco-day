// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IRoycoTrancheHook
/// @notice Minimal interface a Royco tranche calls on every share balance update. The tranche depends only on this single
///         function — any hook implementation (e.g. the blacklist + whitelist hook) implements it.
interface IRoycoTrancheHook {
    /**
     * @notice Tranche balance-update hook: invoked on every tranche transfer/mint/burn to validate the update.
     * @dev Called by a tranche from its `_update`; `msg.sender` is the calling tranche. Reverts to reject the update.
     * @param _caller The address that initiated the balance update
     * @param _from The address the balance is moving from (the null address on mints)
     * @param _to The address the balance is moving to (the null address on burns)
     * @param _enforceWhitelist Whether the calling tranche enforces its transfer whitelist
     */
    function preTrancheBalanceUpdateHook(address _caller, address _from, address _to, bool _enforceWhitelist) external view;
}
