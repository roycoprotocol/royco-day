// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IYDM } from "../../interfaces/IYDM.sol";
import { WAD } from "../../libraries/Constants.sol";

/**
 * @title BaseYDM
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Shared base for Royco yield distribution models (YDMs)
 * @dev A YDM is a general-purpose premium model: it maps a single utilization input to the share of a tranche's yield paid out to a capital pool as a premium for a service the pool provides to that tranche
 * @dev Utilization is the fraction of a capital pool's service capacity that is currently in use: the ratio of demand for the service the pool provides to the pool's capacity to supply it, scaled to WAD precision
 * @dev This base holds the per-instance target utilization (the curve's kink) so the same model can be configured to target any utilization a market measures
 */
abstract contract BaseYDM is IYDM {
    /// @notice The target utilization (the curve's kink) for this YDM instance, scaled to WAD precision
    /// @dev Configured per instance so the same model can target different utilizations
    uint256 public immutable TARGET_UTILIZATION_WAD;

    /**
     * @notice Sets the per-instance target utilization (the kink) shared by every market this YDM serves
     * @dev Must be greater than zero so the curve regions are well defined when utilization is zero, concrete models may further constrain it
     * @param _targetUtilizationWAD The target utilization (the kink) for this model, in the range (0, 100%], scaled to WAD precision
     */
    constructor(uint256 _targetUtilizationWAD) {
        require(_targetUtilizationWAD > 0 && _targetUtilizationWAD <= WAD, INVALID_YDM_INITIALIZATION());
        TARGET_UTILIZATION_WAD = _targetUtilizationWAD;
    }
}
