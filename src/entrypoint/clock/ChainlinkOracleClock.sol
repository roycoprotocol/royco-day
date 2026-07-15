// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IOracleClock } from "../../interfaces/IOracleClock.sol";
import { AggregatorV3Interface } from "../../interfaces/external/chainlink/AggregatorV3Interface.sol";

/**
 * @title ChainlinkOracleClock
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Oracle clock backed by a push-based Chainlink (compatible) oracle
 * @dev The oracle network timestamps its own updates, so the clock passes the feed's latest update timestamp
 */
contract ChainlinkOracleClock is IOracleClock {
    /// @notice The Chainlink (compatible) oracle whose update timestamps this clock reports
    AggregatorV3Interface public immutable ORACLE;

    /// @notice Constructs the clock over the specified Chainlink (compatible) oracle
    /// @param _oracle The Chainlink (compatible) oracle whose update timestamps this clock reports
    constructor(address _oracle) {
        // Set the immutable state
        ORACLE = AggregatorV3Interface(_oracle);
    }

    /// @inheritdoc IOracleClock
    function poke() external view override(IOracleClock) returns (uint32 lastUpdatedAt) {
        (,,, uint256 updatedAt,) = ORACLE.latestRoundData();
        return uint32(updatedAt);
    }

    /// @inheritdoc IOracleClock
    function description() external view override(IOracleClock) returns (string memory clockDescription) {
        return string(abi.encodePacked("Oracle clock reporting the update timestamps of the following feed: ", ORACLE.description()));
    }
}
