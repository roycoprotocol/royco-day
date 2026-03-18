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

    /**
     *  @dev    Gets the address of the globals.
     *  @return globals_ The address of the globals.
     */
    function globals() external view returns (address globals_);

    /**
     *  @dev    Checks if a scheduled call can be executed.
     *  @param  functionId_   The function to check.
     *  @param  caller_       The address of the caller.
     *  @param  data_         The data of the call.
     *  @return canCall_      True if the call can be executed, false otherwise.
     *  @return errorMessage_ The error message if the call cannot be executed.
     */
    function canCall(bytes32 functionId_, address caller_, bytes memory data_) external view returns (bool canCall_, string memory errorMessage_);
}
