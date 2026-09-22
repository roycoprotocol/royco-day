// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IStork, StorkStructs } from "../../src/interfaces/external/stork/IStork.sol";

/**
 * @title MockStork
 * @notice Stork-core-shaped test mock: a per-asset-id store of publisher values with nanosecond timestamps
 * @dev HARD RULE, timestamps are NEVER auto-refreshed: freshness and value are independent knobs, so warping time
 *      genuinely crosses the oracle's per-leg staleness gates
 * @dev The checked getter mirrors the real contract's single contract-wide window (`validTimePeriodSeconds`), so a
 *      suite can pin that the oracle under test does NOT depend on it
 */
contract MockStork is IStork {
    /// @notice Thrown by both getters when revert mode is armed
    error STORK_REVERT_MODE();

    /// @dev A published value; `exists` distinguishes an unpublished id (NotFound) from a zero value
    struct StoredValue {
        bool exists;
        uint64 timestampNs;
        int192 quantizedValue;
    }

    /// @dev The published value per asset id
    mapping(bytes32 id => StoredValue value) private _values;

    /// @dev The contract-wide window the checked getter enforces
    uint256 private _validTimePeriodSeconds = 3600;

    /// @dev Whether the getters revert
    bool private _revertMode;

    /// @notice Publishes (or overwrites) an asset's value
    function setValue(bytes32 _id, uint64 _timestampNs, int192 _quantizedValue) external {
        _values[_id] = StoredValue({ exists: true, timestampNs: _timestampNs, quantizedValue: _quantizedValue });
    }

    /// @notice Removes an asset's value, so reads revert NotFound again
    function removeValue(bytes32 _id) external {
        delete _values[_id];
    }

    /// @notice Sets the checked getter's contract-wide window
    function setValidTimePeriodSeconds(uint256 _seconds) external {
        _validTimePeriodSeconds = _seconds;
    }

    /// @notice Arms or disarms revert mode on both getters
    function setRevertMode(bool _shouldRevert) external {
        _revertMode = _shouldRevert;
    }

    /// @inheritdoc IStork
    function getTemporalNumericValueV1(bytes32 _id) external view override(IStork) returns (StorkStructs.TemporalNumericValue memory value) {
        value = _read(_id);
        // Mirror the core: stale once the value is older than the contract-wide window
        if ((uint256(value.timestampNs) / 1e9) + _validTimePeriodSeconds < block.timestamp) revert StaleValue();
    }

    /// @inheritdoc IStork
    function getTemporalNumericValueUnsafeV1(bytes32 _id) external view override(IStork) returns (StorkStructs.TemporalNumericValue memory value) {
        return _read(_id);
    }

    /// @inheritdoc IStork
    function validTimePeriodSeconds() external view override(IStork) returns (uint256) {
        return _validTimePeriodSeconds;
    }

    /// @inheritdoc IStork
    function version() external pure override(IStork) returns (string memory) {
        return "mock";
    }

    /// @dev Reads a published value, reverting like the core for an unpublished id
    function _read(bytes32 _id) private view returns (StorkStructs.TemporalNumericValue memory value) {
        if (_revertMode) revert STORK_REVERT_MODE();
        StoredValue storage stored = _values[_id];
        if (!stored.exists) revert NotFound();
        return StorkStructs.TemporalNumericValue({ timestampNs: stored.timestampNs, quantizedValue: stored.quantizedValue });
    }
}
