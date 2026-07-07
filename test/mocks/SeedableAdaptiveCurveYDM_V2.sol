// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";

/**
 * @title SeedableAdaptiveCurveYDM_V2
 * @notice AdaptiveCurveYDM_V2 with a test-only setter that places a market's stored curve at an arbitrary
 *         state (yield share at target, adaptation clock, fixed discount and premium spreads), so symbolic
 *         and fuzz suites can cover post-adaptation curve states without executing the time-based
 *         exponential adaptation path
 * @dev The production surface is inherited unchanged, only the direct storage seeding is added
 */
contract SeedableAdaptiveCurveYDM_V2 is AdaptiveCurveYDM_V2 {
    constructor(uint256 _targetUtilizationWAD) AdaptiveCurveYDM_V2(_targetUtilizationWAD) { }

    /// @notice Writes a market's curve state directly, bypassing initialization and adaptation
    function seedCurve(
        address _accountant,
        uint64 _yieldShareAtTargetWAD,
        uint32 _lastAdaptationTimestamp,
        uint64 _discountToTargetAtZeroUtilWAD,
        uint64 _premiumToTargetAtFullUtilWAD
    )
        external
    {
        accountantToCurve[_accountant] = AdaptiveYieldCurve({
            yieldShareAtTargetWAD: _yieldShareAtTargetWAD,
            lastAdaptationTimestamp: _lastAdaptationTimestamp,
            discountToTargetAtZeroUtilWAD: _discountToTargetAtZeroUtilWAD,
            premiumToTargetAtFullUtilWAD: _premiumToTargetAtFullUtilWAD
        });
    }
}
