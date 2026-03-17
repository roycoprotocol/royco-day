// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IMaplePoolManager
/// @notice Abridged interface for a Maple Pool Manager
interface IMaplePoolManager {
    /**
     *  @dev    Gets the address of the pool delegate cover.
     *  @return poolPermissionManager_ The address of the pool permission manager.
     */
    function poolPermissionManager() external view returns (address poolPermissionManager_);
}
