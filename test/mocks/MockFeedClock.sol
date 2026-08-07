// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { SafeCast } from "../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { AggregatorV3Interface } from "../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";

/// @notice Minimal poke-only clock over a Chainlink (compatible) feed for entry point gate tests: forwards the
///         feed's own update timestamp with the loud uint32 cast, the passthrough shape production oracles use
///         for their Chainlink leg
contract MockFeedClock {
    using SafeCast for uint256;

    AggregatorV3Interface public immutable ORACLE;

    constructor(address _oracle) {
        ORACLE = AggregatorV3Interface(_oracle);
    }

    function poke() external view returns (uint32 lastUpdatedAt) {
        (,,, uint256 updatedAt,) = ORACLE.latestRoundData();
        return updatedAt.toUint32();
    }
}
