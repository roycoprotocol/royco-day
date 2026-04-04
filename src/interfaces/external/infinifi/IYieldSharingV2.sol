// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IYieldSharingV2
/// @notice Abridged interface for the Infinifi Yield Sharing V2 contract
interface IYieldSharingV2 {
    /// @notice Distributes any unaccrued yield to stakers and lockers
    /// @dev Call this before reading exchangeRate to ensure it reflects latest profits/losses
    function accrue() external;
}
