// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math, toNAVUnits } from "../../src/libraries/Units.sol";
import { ValuationLogic } from "../../src/libraries/logic/ValuationLogic.sol";

/**
 * @title KernelDepositExposer
 * @notice Thin exposer over the share-conversion primitive exactly as the multi-asset LT deposit sizes its
 *         senior-share leg (floor rounding against the post-sync senior effective NAV and post-mint senior
 *         share supply), so the symbolic layer can drive the production sizing path with arbitrary inputs
 * @dev Stateless: the sizing primitive is a pure library function and reads no kernel storage
 */
contract KernelDepositExposer {
    /// @notice Sizes the senior shares minted for an ST-leg deposit value, floor-rounded like the execution path
    function sizeSTLegShares(uint256 _value, uint256 _stEffectiveNAV, uint256 _totalSTShares) external pure returns (uint256 shares) {
        return ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_stEffectiveNAV), _totalSTShares, Math.Rounding.Floor);
    }
}
