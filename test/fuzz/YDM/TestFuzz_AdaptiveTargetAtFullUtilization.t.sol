// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { WAD, WAD_INT } from "../../../src/libraries/Constants.sol";
import { MarketState } from "../../../src/libraries/Types.sol";
import { EchoAdaptiveCurveYDM } from "../../mocks/EchoAdaptiveCurveYDM.sol";

/**
 * @title TestFuzz_AdaptiveTargetAtFullUtilization
 * @notice Fuzz properties for the adaptive base's degenerate region split when the target utilization (the
 *         kink) is configured at exactly 100%: the above-target region is empty, yet the normalization must
 *         stay total for every utilization input instead of dividing by zero, and the normalized delta must
 *         come out as exactly the clamped utilization minus WAD, always in [-WAD, 0]
 * @dev The delta is observed through the echo model's shifted-delta mode, which returns the signed
 *      normalized delta plus WAD so it fits the unsigned return. The expected form is exact with no rounding
 *      because the below-target branch's divisor is the full WAD target, so multiplying the utilization
 *      shortfall by WAD and dividing by the WAD target cancel perfectly
 */
contract TestFuzz_AdaptiveTargetAtFullUtilization is Test {
    /// @dev The configured lower bound on the adaptive yield share at target: 0.01%
    uint256 internal constant MIN_YT = 1e14;

    /// @dev The configured upper bound on the adaptive yield share at target: 100%
    uint256 internal constant MAX_YT = 1e18;

    /// @dev The deploy-time ceiling on the max adaptation speed: floor(100e18 / 365 days)
    uint256 internal constant MAX_SPEED = 100e18 / uint256(365 days);

    /// @dev Echo instance with the target at exactly 100%, so the above-target region is empty
    EchoAdaptiveCurveYDM internal echoTargetAtFull;

    function setUp() public {
        echoTargetAtFull = new EchoAdaptiveCurveYDM(WAD, MIN_YT, MAX_YT, MAX_SPEED);
        echoTargetAtFull.setEchoMode(EchoAdaptiveCurveYDM.EchoMode.NORMALIZED_DELTA_SHIFTED);
        vm.warp(4_000_000_000);
    }

    /**
     * Property: with the kink at exactly 100% the region normalization never divides by zero for any
     * utilization in the full uint256 range, and the normalized delta is exactly the clamped utilization
     * minus WAD (nonpositive everywhere, -WAD at an empty pool, zero at or beyond full utilization). The
     * clamp forces the utilization to at most the WAD target, so the region selection can never land on the
     * empty above-target region whose width is zero
     */
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_TargetAtFullUtilization_NormalizationIsTotalAndDeltaIsClampedShortfall(uint256 _u, uint256 _storedYT) public {
        uint256 storedYT = bound(_storedYT, MIN_YT, MAX_YT);
        // A zero adaptation clock means the elapsed window reads zero, so the perpetual arm applies no drift
        echoTargetAtFull.seedCurve(storedYT, 0);

        uint256 clamped = _u > WAD ? WAD : _u;
        int256 expected = int256(clamped) - WAD_INT;

        // The frozen arm: no adaptation math at all, the delta is observed directly
        uint256 echoedFrozen = echoTargetAtFull.previewYieldShare(MarketState.FIXED_TERM, _u);
        assertEq(int256(echoedFrozen) - WAD_INT, expected, "frozen-arm delta must be the clamped utilization shortfall");
        assertLe(int256(echoedFrozen) - WAD_INT, 0, "the empty above-target region admits no positive delta");

        // The perpetual arm at zero elapsed: the adaptation path runs and must be equally total
        uint256 echoedLive = echoTargetAtFull.yieldShare(MarketState.PERPETUAL, _u);
        assertEq(int256(echoedLive) - WAD_INT, expected, "perpetual-arm delta must be the clamped utilization shortfall");
    }
}
