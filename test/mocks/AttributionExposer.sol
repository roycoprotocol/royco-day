// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayAccountant } from "../../src/accountant/RoycoDayAccountant.sol";
import { toNAVUnits } from "../../src/libraries/Units.sol";

/**
 * @title AttributionExposer
 * @notice Thin exposer over the accountant's internal pure delta-attribution helper so the fuzz layer can
 *         drive the exact production code path directly with arbitrary (delta, claim, lastRaw) tuples
 * @dev No state is touched and the constructor arguments are dummies: the attribution helper reads neither
 *      the kernel address nor the co-investment flag
 */
contract AttributionExposer is RoycoDayAccountant {
    constructor() RoycoDayAccountant(address(1), true) { }

    /// @notice Calls the production attribution helper on plain uint256 operands
    function attribute(int256 _delta, uint256 _claim, uint256 _lastRaw) external pure returns (int256) {
        return _attributeDeltaToClaimOnRawNAV(_delta, toNAVUnits(_claim), toNAVUnits(_lastRaw));
    }
}
