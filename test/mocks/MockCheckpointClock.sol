// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { OracleCheckpointClockBase } from "../../src/entrypoint/clock/base/OracleCheckpointClockBase.sol";
import { MockValueSource } from "./MockValueSource.sol";

/// @notice Minimal concrete checkpoint clock over a settable value source, exercising the base contract's
///         change-detection semantics and its initialization-time seeding
contract MockCheckpointClock is OracleCheckpointClockBase {
    MockValueSource public immutable SOURCE;

    constructor(address _source) {
        SOURCE = MockValueSource(_source);
    }

    function initialize(address _initialAuthority, uint256 _minDeviationWAD) external initializer {
        __RoycoBase_init(_initialAuthority);
        __OracleCheckpointClockBase_init_unchained(_minDeviationWAD);
    }

    function _readSource() internal view override returns (uint256 value) {
        return SOURCE.getValue();
    }

    function description() external pure override returns (string memory clockDescription) {
        return "Checkpoint clock over a mock value source";
    }
}
