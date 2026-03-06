// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title USDai Interface
 * @author MetaStreet Foundation
 */
interface IUSDai {
    /**
     * @notice Check if an address is blacklisted
     * @param account Account
     * @return Is blacklisted
     */
    function isBlacklisted(address account) external view returns (bool);
}
