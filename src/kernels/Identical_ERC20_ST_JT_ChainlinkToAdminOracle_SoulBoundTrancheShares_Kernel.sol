// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel, RoycoKernel } from "./Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel.sol";

/**
 * @title Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel
 * @author Waymont
 * @notice Extends the Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel by making tranche shares soul-bound
 * @dev Primarily used for RWAs and digital securities with transfer agent obligations
 */
contract Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel is Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel {
    /// @dev Thrown when a senior or junior tranche LP trys to transfer tranche shares to another LP
    error TRANCHE_SHARES_ARE_SOUL_BOUND();

    /// @notice Constructs the kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoKernelConstructionParams memory _params) Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(_params) { }

    /// @inheritdoc RoycoKernel
    function _preTrancheBalanceUpdate(address _from, address _to, uint256) internal pure override(RoycoKernel) {
        // Only allow transfers between the zero address and a non-zero address (redeem and mint)
        bool isMintOrRedeem;
        assembly ("memory-safe") {
            isMintOrRedeem := xor(eq(_from, 0), eq(_to, 0))
        }
        require(isMintOrRedeem, TRANCHE_SHARES_ARE_SOUL_BOUND());
    }
}
