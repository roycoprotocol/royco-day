// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AggregatorV3Interface } from "../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";

/**
 * @title MockAggregatorV3
 * @notice Chainlink-shaped aggregator test mock serving as both the price feed and the L2 sequencer-uptime feed
 * @dev HARD RULE, updatedAt is NEVER auto-refreshed, freshness and price are independent knobs so warping time genuinely crosses the staleness gate
 * @dev The constructor stamps the initial round once, after that every field moves only through its setter
 */
contract MockAggregatorV3 is AggregatorV3Interface {
    /// @notice Thrown by both round-data getters when revert mode is armed
    error ORACLE_REVERT_MODE();

    /// @dev The reported oracle decimals
    uint8 private _decimals;

    /// @dev The latest round id
    uint80 private _roundId;

    /// @dev The latest answer (the price, or the sequencer status when used as an uptime feed)
    int256 private _answer;

    /// @dev The timestamp the latest round started at (the restore timestamp when used as an uptime feed)
    uint256 private _startedAt;

    /// @dev The timestamp the latest round was updated at, never auto-refreshed
    uint256 private _updatedAt;

    /// @dev The round id the latest answer was computed in
    uint80 private _answeredInRound;

    /// @dev Whether the round-data getters revert
    bool private _revertMode;

    /**
     * @notice Deploys the mock aggregator with a single fresh round
     * @param _initialDecimals The oracle decimals
     * @param _initialAnswer The initial answer, scaled to the oracle decimals
     */
    constructor(uint8 _initialDecimals, int256 _initialAnswer) {
        _decimals = _initialDecimals;
        _roundId = 1;
        _answer = _initialAnswer;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = 1;
    }

    // =============================
    // AggregatorV3Interface Surface
    // =============================

    /// @inheritdoc AggregatorV3Interface
    function decimals() external view override(AggregatorV3Interface) returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external pure override(AggregatorV3Interface) returns (string memory) {
        return "MockAggregatorV3";
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure override(AggregatorV3Interface) returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev Returns the stored round regardless of the requested round id, the consumers under test only read the latest round
    function getRoundData(uint80)
        external
        view
        override(AggregatorV3Interface)
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        require(!_revertMode, ORACLE_REVERT_MODE());
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    /// @inheritdoc AggregatorV3Interface
    function latestRoundData()
        external
        view
        override(AggregatorV3Interface)
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        require(!_revertMode, ORACLE_REVERT_MODE());
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    // =============================
    // Field Knobs (each independent, none touch updatedAt except its own setter)
    // =============================

    /// @notice Sets every round field in one call
    function setAll(uint80 _newRoundId, int256 _newAnswer, uint256 _newStartedAt, uint256 _newUpdatedAt, uint80 _newAnsweredInRound) external {
        _roundId = _newRoundId;
        _answer = _newAnswer;
        _startedAt = _newStartedAt;
        _updatedAt = _newUpdatedAt;
        _answeredInRound = _newAnsweredInRound;
    }

    /// @notice Sets the answer WITHOUT touching updatedAt, so a price move never implicitly refreshes staleness
    function setAnswer(int256 _newAnswer) external {
        _answer = _newAnswer;
    }

    /// @notice Sets the oracle decimals
    function setDecimals(uint8 _newDecimals) external {
        _decimals = _newDecimals;
    }

    /// @notice Sets the round updated-at timestamp, the only way freshness moves
    function setUpdatedAt(uint256 _newUpdatedAt) external {
        _updatedAt = _newUpdatedAt;
    }

    /// @notice Sets the round started-at timestamp (the sequencer restore timestamp when used as an uptime feed)
    function setStartedAt(uint256 _newStartedAt) external {
        _startedAt = _newStartedAt;
    }

    /// @notice Sets the latest round id
    function setRoundId(uint80 _newRoundId) external {
        _roundId = _newRoundId;
    }

    /// @notice Sets the round id the latest answer was computed in
    function setAnsweredInRound(uint80 _newAnsweredInRound) external {
        _answeredInRound = _newAnsweredInRound;
    }

    /// @notice Arms or disarms the revert mode on both round-data getters
    function setRevertMode(bool _shouldRevert) external {
        _revertMode = _shouldRevert;
    }
}
