// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IMapleGlobals
/// @notice Abridged interface for the Maple Globals
interface IMapleGlobals {
    function isFunctionPaused(bytes4 sig_) external view returns (bool isFunctionPaused_);
}
