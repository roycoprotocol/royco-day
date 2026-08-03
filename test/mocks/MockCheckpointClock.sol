// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { OracleClockBase } from "../../src/oracle/base/clock/OracleClockBase.sol";
import { MockValueSource } from "./MockValueSource.sol";

/// @notice Minimal concrete checkpoint clock over a settable value source, exercising the base contract's
///         change-detection semantics and its construction-time baseline seeding
/// @dev Mirrors the production shape: the baseline is read from the source as a constructor argument (the base
///      cannot reach this contract's immutables yet), so a broken source fails the deployment loudly
contract MockCheckpointClock is OracleClockBase {
    MockValueSource public immutable SOURCE;

    constructor(
        address _source,
        uint32 _lastUpdate,
        uint256 _minDeviationWAD
    )
        OracleClockBase(_lastUpdate, _minDeviationWAD, MockValueSource(_source).getValue())
    {
        SOURCE = MockValueSource(_source);
    }

    function _getSourcePrice() internal view override returns (uint256 value) {
        return SOURCE.getValue();
    }
}
