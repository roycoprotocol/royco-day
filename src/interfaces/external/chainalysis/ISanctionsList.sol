// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ISanctionsList
/// @notice Abridged interface for Chainalysis's sanctions list
interface ISanctionsList {
    /// @notice Returns whether or not the specified address has been included in a sanctions designation
    function isSanctioned(address addr) external view returns (bool);
}
