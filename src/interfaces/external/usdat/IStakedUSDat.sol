// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IStakedUSDat
 * @author Saturn
 */
interface IStakedUSDat {
    /**
     * @notice Checks if an address is blacklisted.
     * @param account The address to check.
     * @return True if the address is blacklisted, false otherwise.
     */
    function isBlacklisted(address account) external view returns (bool);
}
