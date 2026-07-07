// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { RoycoDayAccountant } from "../../src/accountant/RoycoDayAccountant.sol";
import { NAV_UNIT, toNAVUnits } from "../../src/libraries/Units.sol";

/**
 * @title AttributionDriver
 * @notice Exposes the accountant's internal signed PnL attribution helper for symbolic execution. The helper is
 *         pure, so the driver deploys with a dummy kernel address and never touches accountant state
 */
contract AttributionDriver is RoycoDayAccountant {
    constructor() RoycoDayAccountant(address(1), false) { }

    /// @dev Pass-through to the internal pure attribution helper under test
    function attributeDelta(int256 _delta, NAV_UNIT _claim, NAV_UNIT _lastRaw) external pure returns (int256) {
        return _attributeDeltaToClaimOnRawNAV(_delta, _claim, _lastRaw);
    }
}

/**
 * @title AttributionSymbolicSpec
 * @notice Halmos symbolic specs for the signed PnL attribution step of the tranche accounting sync
 *         (_attributeDeltaToClaimOnRawNAV). The load-bearing properties: a zero delta, claim, or checkpoint
 *         NAV attributes nothing, every other attribution is the exactly floored pro-rata slice of the delta
 *         with the delta's sign preserved and magnitude never exceeding the delta, and splitting one claim
 *         into two loses at most one wei to flooring in the direction that shorts the claimant (the
 *         complementary tranche absorbs the dust)
 * @dev Run with `halmos --contract AttributionSymbolicSpec`. Functions prefixed check_ are halmos properties and
 *      are not discovered by forge test. Domain: NAVs up to 1e30 wei and deltas in [-1e30, 1e30], the suite-wide
 *      bounds. The expected floor is derived independently as plain integer division, not through OZ mulDiv
 */
contract AttributionSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei
    uint256 internal constant MAX_NAV = 1e30;

    AttributionDriver internal driver;

    function setUp() public {
        driver = new AttributionDriver();
    }

    /// @notice A zero delta, a zero claim, or a zero last-checkpoint NAV attributes exactly nothing, so an empty
    ///         tranche can never be handed a share of someone else's PnL
    function check_zeroDeltaClaimOrCheckpointAttributesNothing(int256 delta, uint256 claim, uint256 lastRaw) external view {
        vm.assume(delta >= -int256(MAX_NAV) && delta <= int256(MAX_NAV));
        vm.assume(claim <= MAX_NAV && lastRaw <= MAX_NAV);

        int256 attributed = driver.attributeDelta(delta, toNAVUnits(claim), toNAVUnits(lastRaw));
        if (delta == 0 || claim == 0 || lastRaw == 0) assert(attributed == 0);
    }

    /**
     * @notice The attributed slice is exactly floor(|delta| * claim / lastRaw) with the delta's sign re-applied:
     *         the magnitude floors toward zero on both signs (a loss is never over-attributed and a gain never
     *         rounds up), the sign always matches the delta, and because the claim never exceeds the checkpoint
     *         NAV the slice never exceeds the whole delta
     */
    function check_attributionIsTheFlooredProRataSliceWithSignPreserved(int256 delta, uint256 claim, uint256 lastRaw) external view {
        // A live checkpoint with a claim on part of it: 0 < claim <= lastRaw
        vm.assume(delta >= -int256(MAX_NAV) && delta <= int256(MAX_NAV) && delta != 0);
        vm.assume(1 <= lastRaw && lastRaw <= MAX_NAV);
        vm.assume(1 <= claim && claim <= lastRaw);

        int256 attributed = driver.attributeDelta(delta, toNAVUnits(claim), toNAVUnits(lastRaw));

        // Independent floor derivation: plain integer division of the magnitude, sign re-applied afterwards
        uint256 absDelta = delta < 0 ? uint256(-delta) : uint256(delta);
        uint256 expectedMagnitude = (absDelta * claim) / lastRaw;
        if (delta > 0) {
            assert(attributed == int256(expectedMagnitude));
            // claim <= lastRaw caps the slice at the whole delta
            assert(attributed <= delta);
        } else {
            assert(attributed == -int256(expectedMagnitude));
            assert(attributed >= delta);
        }
    }

    /**
     * @notice Attributing one delta to two claims separately recovers the single-claim attribution of their sum to
     *         within one wei, and the flooring drift always shorts the split side: on a gain the two slices sum to
     *         at most the whole (never over-paying), on a loss they sum to at least the whole (never
     *         over-charging), so the complementary tranche silently absorbs at most one wei of dust
     */
    function check_splittingAClaimLosesAtMostOneWeiAgainstTheSplitSide(int256 delta, uint256 claimA, uint256 claimB, uint256 lastRaw) external view {
        // Two disjoint claims on one live checkpoint
        vm.assume(delta >= -int256(MAX_NAV) && delta <= int256(MAX_NAV) && delta != 0);
        vm.assume(1 <= lastRaw && lastRaw <= MAX_NAV);
        vm.assume(claimA <= lastRaw && claimB <= lastRaw - claimA);

        int256 whole = driver.attributeDelta(delta, toNAVUnits(claimA + claimB), toNAVUnits(lastRaw));
        int256 splitSum =
            driver.attributeDelta(delta, toNAVUnits(claimA), toNAVUnits(lastRaw)) + driver.attributeDelta(delta, toNAVUnits(claimB), toNAVUnits(lastRaw));

        if (delta > 0) {
            // On a gain the two floors can only under-pay the split side, by at most one wei combined
            assert(splitSum <= whole);
            assert(whole - splitSum <= 1);
        } else {
            // On a loss the two floors can only under-charge the split side, by at most one wei combined
            assert(splitSum >= whole);
            assert(splitSum - whole <= 1);
        }
    }
}
