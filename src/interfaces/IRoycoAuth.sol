// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

interface IRoycoAuth {
    /// @dev Thrown when an address is set to the null address
    error NULL_ADDRESS();

    /// @notice Pauses the contract
    function pause() external;

    /// @notice Unpauses the contract
    function unpause() external;
}
