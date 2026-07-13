// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ITrancheOracleClock } from "../../interfaces/ITrancheOracleClock.sol";
import { AggregatorV3Interface } from "../../interfaces/external/chainlink/AggregatorV3Interface.sol";

/**
 * @title ChainlinkOracleClock
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Oracle clock backed by a push-based Chainlink (compatible) oracle
 * @dev The oracle network timestamps its own updates, so the clock passes the feed's latest update timestamp
 */
contract ChainlinkOracleClock is ITrancheOracleClock {
    /// @notice The Chainlink (compatible) oracle whose update timestamps this clock reports
    AggregatorV3Interface public immutable ORACLE;

    /// @notice Thrown when the provided Chainlink (compatible) oracle is the null address
    error NULL_ADDRESS();

    /// @notice Constructs the clock over the specified Chainlink (compatible) oracle
    /// @param _oracle The Chainlink (compatible) oracle whose update timestamps this clock reports
    constructor(address _oracle) {
        // Ensure the oracle isn't null
        require(_oracle != address(0), NULL_ADDRESS());

        // Set the immutable state
        ORACLE = AggregatorV3Interface(_oracle);
    }

    /// @inheritdoc ITrancheOracleClock
    function poke() external view override(ITrancheOracleClock) returns (uint32 lastUpdatedAt) {
        (,,, uint256 updatedAt,) = ORACLE.latestRoundData();
        return uint32(updatedAt);
    }
}
