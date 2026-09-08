// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DiscretePriceOracleBase } from "../../src/oracle/base/DiscretePriceOracleBase.sol";
import { MockValueSource } from "./MockValueSource.sol";

/**
 * @notice Minimal concrete discrete composed oracle over a settable source and a mock feed, exercising the
 *         base's owner-driven checkpoint latch, checkpointed conversion hop, and oldest-hop reporting
 * @dev Mirrors the production shape: only the source read is supplied, so a fresh deployment carries the
 *      base's zero checkpoint and stays shut until the owner's first checkpointPrice call
 */
contract MockDiscretePriceOracle is DiscretePriceOracleBase {
    MockValueSource public immutable SOURCE;

    constructor(
        address _owner,
        address _collateralAsset,
        address _chainlinkOracle,
        address _source,
        uint32 _chainlinkOracleStalenessThresholdSeconds,
        uint32 _sourcePriceStalenessThresholdSeconds
    )
        DiscretePriceOracleBase(_owner, _collateralAsset, _chainlinkOracle, _chainlinkOracleStalenessThresholdSeconds, _sourcePriceStalenessThresholdSeconds)
    {
        SOURCE = MockValueSource(_source);
    }

    function _getSourcePrice() internal view override returns (uint256 price) {
        return SOURCE.getValue();
    }
}
