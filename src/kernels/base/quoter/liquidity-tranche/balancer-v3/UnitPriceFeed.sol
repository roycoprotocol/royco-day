// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AggregatorV3Interface } from "../../../../../interfaces/external/chainlink/AggregatorV3Interface.sol";

/**
 * @title UnitPriceFeed
 * @author Waymont
 * @notice A constant Chainlink-compatible feed that always answers 1.0 (18 decimals) at the current block time
 * @notice Used as the market price feed for the senior-tranche leg of the LT's Balancer pool inside the E-CLP BPT
 *         oracle: the leg is `WITH_RATE` and the kernel's rate provider already converts its live balance into NAV
 *         units (USD), so the leg's residual market price against the oracle's numeraire is identically 1
 * @dev Stateless and market-independent: one instance (deployed once per template) serves every market
 */
contract UnitPriceFeed is AggregatorV3Interface {
    /// @dev 1.0 at 18 decimals of feed precision
    int256 private constant UNIT_ANSWER = 1e18;

    /// @inheritdoc AggregatorV3Interface
    function decimals() external pure override(AggregatorV3Interface) returns (uint8) {
        return 18;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external pure override(AggregatorV3Interface) returns (string memory) {
        return "Constant 1.0 unit price feed (rate-provider-priced leg)";
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure override(AggregatorV3Interface) returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev `updatedAt` is the current block time so the constant answer is never treated as stale by consumers
    function latestRoundData()
        external
        view
        override(AggregatorV3Interface)
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, UNIT_ANSWER, block.timestamp, block.timestamp, 0);
    }

    /// @inheritdoc AggregatorV3Interface
    function getRoundData(uint80)
        external
        view
        override(AggregatorV3Interface)
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, UNIT_ANSWER, block.timestamp, block.timestamp, 0);
    }
}
