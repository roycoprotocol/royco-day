// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel, RoycoKernel } from "./Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel.sol";

/**
 * @title Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel
 * @author Waymont
 * @notice Extends the identical-asset Chainlink-to-admin-oracle kernel with soul-bound tranche shares
 * @dev Tranche shares are non-transferable: only mints (from zero address) and burns/redeems (to zero address) are
 *      permitted. Peer-to-peer transfers revert with TRANCHE_SHARES_TRANSFER_NOT_PERMITTED.
 *      The transfer agent can still seize shares via seizeShares() and seizeAndRedeemShares(), which bypass this hook
 *      by calling super._update() directly on the tranche.
 */
contract Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel is Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel {
    error TRANCHE_SHARES_TRANSFER_NOT_PERMITTED();

    /// @notice Constructs the kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoKernelConstructionParams memory _params) Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(_params) { }

    /// @inheritdoc RoycoKernel
    function _preTrancheBalanceUpdate(address _from, address _to, uint256) internal pure override(RoycoKernel) {
        // Only allow transfers between the zero address and a non-zero address (redeem and mint)
        bool isMintOrRedeem = false;
        assembly ("memory-safe") {
            isMintOrRedeem := xor(eq(_from, 0), eq(_to, 0))
        }

        require(isMintOrRedeem, TRANCHE_SHARES_TRANSFER_NOT_PERMITTED());
    }
}
