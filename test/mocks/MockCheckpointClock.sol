// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { OracleClockBase } from "../../src/oracle/base/clock/OracleClockBase.sol";
import { MockValueSource } from "./MockValueSource.sol";

/// @notice Minimal concrete checkpoint clock over a settable value source, exercising the base contract's
///         change-detection semantics and its construction-time baseline seeding
/// @dev Mirrors the production shape: the constructor body assigns the source then checkpoints the baseline
///      through the same _getSourcePrice read every poke uses, so a broken source fails the deployment loudly
contract MockCheckpointClock is OracleClockBase {
    MockValueSource public immutable SOURCE;

    constructor(address _source, uint32 _lastUpdate, uint256 _minDeviationWAD) OracleClockBase(_lastUpdate, _minDeviationWAD) {
        SOURCE = MockValueSource(_source);
        _initializeOracleClock(_getSourcePrice());
    }

    /// @notice Attempts to rewrite the clock baseline after construction, exercising the construction-only guard
    function attemptRuntimeBaselineRewrite(uint256 _initialOraclePrice) external {
        _initializeOracleClock(_initialOraclePrice);
    }

    function _getSourcePrice() internal view override returns (uint256 value) {
        return SOURCE.getValue();
    }
}
