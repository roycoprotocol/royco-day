// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IMapleGlobals
/// @notice Abridged interface for the Maple Globals
interface IMapleGlobals {
    /**
     *  @dev    Gets whether a contract's function is paused.
     *  @param  contract_         The address of a contract in the protocol.
     *  @param  sig_              The function signature within the contract.
     *  @return isFunctionPaused_ Whether the contract's function is paused.
     */
    function isFunctionPaused(address contract_, bytes4 sig_) external view returns (bool isFunctionPaused_);
}
