// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DiscretePriceOracleBase } from "../../src/oracle/base/DiscretePriceOracleBase.sol";
import { MockValueSource } from "./MockValueSource.sol";

/**
 * @notice Minimal concrete discrete composed oracle over a settable source and a mock feed, exercising the
 *         base's ID-and-distress checkpoint latch, checkpointed conversion hop, and oldest-hop reporting
 * @dev Mirrors the production shape: the checkpoint ID is a settable counter so settlements are driven
 *      explicitly, the force-checkpoint flag is a settable bit modeling a distressed source, and the constructor
 *      seeds the baseline through the shared commit path
 */
contract MockDiscretePriceOracle is DiscretePriceOracleBase {
    MockValueSource public immutable SOURCE;

    /// @dev The settable checkpoint ID: a bump models a settlement, a frozen ID models a distressed source
    uint256 public checkpointId;

    /// @dev The settable force-checkpoint flag: true models a source repricing outside its settlements
    bool public forceCheckpoint;

    constructor(
        address _collateralAsset,
        address _chainlinkOracle,
        address _source,
        uint32 _chainlinkOracleStalenessThresholdSeconds,
        uint32 _sourcePriceStalenessThresholdSeconds
    )
        DiscretePriceOracleBase(_collateralAsset, _chainlinkOracle, _chainlinkOracleStalenessThresholdSeconds, _sourcePriceStalenessThresholdSeconds)
    {
        SOURCE = MockValueSource(_source);
        _checkpointSourcePrice();
    }

    /// @notice Sets the checkpoint ID the settlement clause observes
    function setCheckpointId(uint256 _checkpointId) external {
        checkpointId = _checkpointId;
    }

    /// @notice Sets the force-checkpoint flag the force clause is conditioned on
    function setForceCheckpoint(bool _forceCheckpoint) external {
        forceCheckpoint = _forceCheckpoint;
    }

    function _getSourcePrice() internal view override returns (uint256 price) {
        return SOURCE.getValue();
    }

    function _getCheckpointId() internal view override returns (uint256 id) {
        return checkpointId;
    }

    function _shouldForceCheckpoint() internal view override returns (bool) {
        return forceCheckpoint;
    }
}
