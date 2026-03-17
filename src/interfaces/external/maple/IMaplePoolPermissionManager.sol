// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IMaplePoolPermissionManager
/// @notice Abridged interface for a Maple Pool Permission Manager
interface IMaplePoolPermissionManager {
    function hasPermission(address poolManager, address caller, bytes32 functionId) external view returns (bool allowed);

    function hasPermission(address poolManager, address[] calldata caller, bytes32 functionId) external view returns (bool allowed);
}
