// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title IDSToken
 * @notice Interface for the DS-Token contract
 * @dev Extends IERC20
 */
interface IDSToken is IERC20 {
    /// @notice Identifier of the compliance service that the token is compliant with
    function COMPLIANCE_SERVICE() external view returns (uint256);

    /// @notice Returns the address of the compliance service for the given identifier
    /// @param _serviceId The identifier of the compliance service
    /// @return The address of the compliance service
    function getDSService(uint256 _serviceId) external view returns (address);
}
