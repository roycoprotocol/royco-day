// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { ValuationLogic } from "../../src/libraries/logic/ValuationLogic.sol";

/**
 * @title ValuationConversionExposer
 * @notice External exposer over the two pure NAV/share conversion primitives in ValuationLogic, deployed as a
 *         standalone contract so the symbolic engine treats each conversion as a message-call boundary
 * @dev The internal library math is division-shaped (OZ mulDiv), which the native symbolic engine's built-in
 *      arithmetic heuristic cannot conclude on when the call is inlined into a test body. Routing every
 *      conversion through this separate contract, exactly as the attribution and tranche-claims specs do,
 *      pushes the query to the real SMT solver
 */
contract ValuationConversionExposer {
    /// @notice The value-to-shares conversion with the mint-dilution clamp, in either rounding mode
    function convertToShares(uint256 _value, uint256 _totalValue, uint256 _totalSupply, bool _roundUp) external pure returns (uint256) {
        return ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _totalSupply, _roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor);
    }

    /// @notice The shares-to-value conversion, the inverse primitive, in either rounding mode
    function convertToValue(uint256 _shares, uint256 _totalSupply, uint256 _totalValue, bool _roundUp) external pure returns (uint256) {
        return toUint256(ValuationLogic._convertToValue(_shares, _totalSupply, toNAVUnits(_totalValue), _roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor));
    }
}
