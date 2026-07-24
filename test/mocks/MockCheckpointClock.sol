// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { OracleClockBase } from "../../src/oracle/base/clock/OracleClockBase.sol";
import { MockValueSource } from "./MockValueSource.sol";

/// @notice Minimal concrete checkpoint clock over a settable value source, exercising the base contract's
///         change-detection semantics and its initialization-time seeding
contract MockCheckpointClock is OracleClockBase {
    MockValueSource public immutable SOURCE;

    constructor(address _source) {
        SOURCE = MockValueSource(_source);
    }

    function initialize(address _initialAuthority, uint256 _minDeviationWAD, uint32 _lastUpdate) external initializer {
        __RoycoBase_init(_initialAuthority);
        __OracleClockBase_init_unchained(_lastUpdate, _minDeviationWAD);
    }

    function _getSourcePrice() internal view override returns (uint256 value) {
        return SOURCE.getValue();
    }
}
