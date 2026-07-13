// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { OracleCheckpointClockBase } from "../../src/entrypoint/clock/base/OracleCheckpointClockBase.sol";
import { MockValueSource } from "./MockValueSource.sol";

/// @notice Minimal concrete checkpoint clock over a settable value source, exercising the base contract's
///         change-detection semantics and its end-of-constructor seeding contract
contract MockCheckpointClock is OracleCheckpointClockBase {
    MockValueSource public immutable SOURCE;

    constructor(address _source, uint256 _minDeviationWAD) OracleCheckpointClockBase(_minDeviationWAD) {
        SOURCE = MockValueSource(_source);
        // Seed the first checkpoint at the END of construction, after the read wiring is set
        _seedCheckpoint();
    }

    function _readSource() internal view override returns (uint256 value) {
        return SOURCE.getValue();
    }
}
