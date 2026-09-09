// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/**
 * @title IIdleCreditVault
 * @author Idle Labs Inc.
 * @notice Abridged interface for the epochic Idle CDO variant's credit vault strategy
 */
interface IIdleCreditVault {
    /// @notice The number of successfully settled epochs
    /// @dev Increments exactly once per successful stopEpoch and never on a borrower default, so it is the CDO's settlement counter
    function epochNumber() external view returns (uint256);
}
