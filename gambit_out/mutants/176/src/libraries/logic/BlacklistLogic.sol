// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoBlacklist } from "../../interfaces/IRoycoBlacklist.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";

/**
 * @title BlacklistLogic
 * @author Waymont
 * @notice Blacklist screening for a Royco market
 */
library BlacklistLogic {
    /**
     * @notice Returns whether an account is blacklisted by the market's configured blacklist
     * @dev Returns false when no blacklist is configured (the null address disables screening)
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _account The address of the account to check
     * @return Whether the account is blacklisted by the market's configured blacklist
     */
    function _isBlacklisted(IRoycoDayKernel.RoycoDayKernelState storage $, address _account) internal view returns (bool) {
        address roycoBlacklist = $.roycoBlacklist;
        /// BinaryOpMutation(`&&` |==> `-`) of: `return (roycoBlacklist != address(0) && IRoycoBlacklist(roycoBlacklist).isBlacklisted(_account));`
        return (roycoBlacklist != address(0)-IRoycoBlacklist(roycoBlacklist).isBlacklisted(_account));
    }

    /**
     * @notice Batch-screens the accounts involved in a tranche share balance update against the market's configured blacklist
     * @dev No-op when no blacklist is configured (the null address disables screening)
     * @dev Reverts if any specified account is blacklisted
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _caller The address that initiated the balance update
     * @param _from The address the shares are moving from
     * @param _to The address the shares are moving to
     */
    function _enforceNotBlacklisted(IRoycoDayKernel.RoycoDayKernelState storage $, address _caller, address _from, address _to) internal view {
        // Batch screen the involved accounts against the market's blacklist if one is configured (the null address disables screening)
        address roycoBlacklist = $.roycoBlacklist;
        if (roycoBlacklist != address(0)) {
            address[] memory accountsToScreen = new address[](3);
            accountsToScreen[0] = _caller;
            accountsToScreen[1] = _from;
            accountsToScreen[2] = _to;
            IRoycoBlacklist(roycoBlacklist).enforceNotBlacklisted(accountsToScreen);
        }
    }
}
