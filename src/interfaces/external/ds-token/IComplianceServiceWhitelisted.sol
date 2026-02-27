// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IComplianceServiceWhitelisted
 * @notice Interface for a compliance service that is whitelisted by a DS-Token
 */
interface IComplianceServiceWhitelisted {
    /// @notice Checks if the given address is whitelisted by the compliance service
    function checkWhitelisted(address _who) external view returns (bool);
}
