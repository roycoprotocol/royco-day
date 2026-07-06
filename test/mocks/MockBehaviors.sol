// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title MockBehaviors
 * @notice Shared token behavior flag constants for the configurable test mocks
 * @dev OR-able bitmap flags consumed by MockERC20C.setBehaviors, BEHAVIOR_NONE is a fully standard ERC20
 * @dev Single source of truth for mocks and fixtures, mirroring the flag values declared in test/scaffold/TrancheFixture.sol
 */
library MockBehaviors {
    /// @dev No non-standard behavior, a fully standard ERC20
    uint256 internal constant BEHAVIOR_NONE = 0;

    /// @dev feeBps applies on every transfer
    uint256 internal constant BEHAVIOR_FEE_ON_TRANSFER = 1 << 0;

    /// @dev Balances scale by a settable index
    uint256 internal constant BEHAVIOR_REBASING = 1 << 1;

    /// @dev USDT-style empty returndata on transfer and transferFrom
    uint256 internal constant BEHAVIOR_NO_RETURN_VALUE = 1 << 2;

    /// @dev Reverts on zero-amount transfer and transferFrom
    uint256 internal constant BEHAVIOR_REVERT_ON_ZERO = 1 << 3;

    /// @dev Per-address deny list
    uint256 internal constant BEHAVIOR_BLOCKLIST = 1 << 4;

    /// @dev Global pause switch on transfers
    uint256 internal constant BEHAVIOR_PAUSABLE = 1 << 5;

    /// @dev Calls a hook target on transfer (reentrancy probe)
    uint256 internal constant BEHAVIOR_HOOK_ON_TRANSFER = 1 << 6;
}
