// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMachine
/// @notice Abridged interface for a Makina machine
interface IMachine {
    /// @notice Address of the share token.
    function shareToken() external view returns (address);

    /// @notice Address of the accounting token.
    function accountingToken() external view returns (address);

    /**
     * @notice Returns the amount of accounting tokens that the Machine would exchange for the amount of shares provided.
     * @param shares The amount of shares.
     * @return assets The amount of accounting tokens.
     */
    function convertToAssets(uint256 shares) external view returns (uint256);
}
