// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_PremiumDustAndFixedTermEdges
 * @notice Accountant-layer edge behaviors that reproduce on the mock-kernel accountant base: a dust-sized senior
 *         gain pays premiums with no protocol fee, and the fixed-term end timestamp truncates to uint32 near the
 *         timestamp ceiling
 * @dev Each test drives the accountant through legal MockKernel post-op and pre-op calls and asserts the
 *      resulting behavior
 */
contract Test_PremiumDustAndFixedTermEdges is AccountantTestBase {
    uint256 internal constant WAD = 1e18;

    // =============================
    // A dust-sized senior gain pays premiums but skips every protocol fee
    // =============================

    /**
     * @notice When a senior gain is at or below the effective dust tolerance, the JT risk premium and LT
     *         liquidity premium are still paid, but all protocol fees are suppressed, because the fee gate keys
     *         on `stGain > effectiveNAVDustTolerance` (RoycoDayAccountant.sol:594) rather than on the premium
     *         being nonzero. A premium is distributed with no protocol fee taken on it
     * @dev The premium is paid (ltLiquidityPremium > 0) while stProtocolFee/jtProtocolFee/ltProtocolFee are all
     *      zero
     * @dev Derivation (dust = stNAVDust 1e12 + jtNAVDust 0 = 1e12, previewYieldShare 0.1e18 for both YDMs, both
     *      capped at the deployed max yield share 0.1e18): a same-block gain of stGain = 5e11 is below the 1e12 dust, so
     *      premiumsPaid stays false. Instantaneous premiums: ltLiquidityPremium = 5e11 x 0.1e18 / 1e18 = 5e10, and
     *      jtRiskPremium = 5e11 x 0.1e18 / 1e18 = 5e10, their sum 1e11 <= the 5e11 gain. Every fee is gated on
     *      premiumsPaid, so all three protocol fees are zero
     */
    function test_dustSizedGain_paysPremiumsWithZeroProtocolFee() public {
        // Deploy with a 1e12-wei effective dust tolerance so a sub-dust gain is easy to construct
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(1e12));
        _deploy(true, p);

        // Pin the instantaneous yield shares both YDMs report so the premium is a fixed constant
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.1e18);

        // Seed a flat committed checkpoint, then a same-block flat sync to initialize the premium accrual clock
        _seedSymmetric(1000e18, 200e18, 100e18);
        kernel.doPreOp(toNAVUnits(uint256(1000e18)), toNAVUnits(uint256(200e18)));

        // A same-block +5e11 senior gain (below the 1e12 dust) takes the instantaneous premium branch
        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(uint256(1000e18 + 5e11)), toNAVUnits(uint256(200e18)));

        // The liquidity premium (and JT risk premium) are paid on the dust gain
        assertEq(toUint256(s.ltLiquidityPremium), 5e10, "ltLiquidityPremium must be 5e11 x 0.1e18 / 1e18 = 5e10");
        // Every protocol fee is suppressed because premiumsPaid stayed false
        assertEq(toUint256(s.ltProtocolFee), 0, "ltProtocolFee is skipped for a dust gain despite the premium being paid");
        assertEq(toUint256(s.stProtocolFee), 0, "stProtocolFee is skipped for a dust gain");
        assertEq(toUint256(s.jtProtocolFee), 0, "jtProtocolFee is skipped for a dust gain");
    }

    // =============================
    // The fixed-term end timestamp truncates to uint32 near the timestamp ceiling
    // =============================

    /**
     * @notice Entering FIXED_TERM near the uint32 timestamp ceiling truncates the fixed-term end to uint32
     *         (RoycoDayAccountant.sol:705, `uint32(block.timestamp + fixedTermDurationSeconds)`), wrapping it to
     *         a value in the past, so the market enters FIXED_TERM already elapsed
     * @dev The sum block.timestamp + fixedTermDurationSeconds overflows uint32 and wraps, committing an end
     *      timestamp far below the current time
     * @dev Derivation (fixedTermDuration 604800s, warp to bigT = 2^32 - 1 - 100 = 4294967195): a covered -10e18
     *      senior loss on a 100e18/30e18 seed enters FIXED_TERM. The true end is bigT + 604800 = 4295571995, which
     *      overflows uint32 (max 4294967295) and wraps to 4295571995 - 4294967296 = 604699, far below bigT
     */
    function test_fixedTermEndTimestamp_truncatesToUint32NearCeiling() public {
        _deploy(true, _defaultParams());

        // Seed a healthy PERPETUAL checkpoint
        _seedSymmetric(100e18, 30e18, 10e18);

        // Warp to just below the uint32 timestamp ceiling
        uint256 bigT = uint256(type(uint32).max) - 100;
        vm.warp(bigT);

        // A covered -10e18 senior loss enters FIXED_TERM (coverage utilization 0.6e18 < the 1.1e18 liquidation threshold)
        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(uint256(90e18)), toNAVUnits(uint256(30e18)));
        assertEq(uint8(s.marketState), uint8(MarketState.FIXED_TERM), "the covered loss must enter FIXED_TERM");

        // The committed end timestamp wrapped to 604699 (bigT + 604800 - 2^32)
        assertEq(uint256(s.fixedTermEndTimestamp), 604_699, "fixedTermEndTimestamp truncated and wrapped to 604699");
        assertLt(uint256(s.fixedTermEndTimestamp), bigT, "the wrapped end timestamp is in the past, so the fixed term is already elapsed");
        assertEq(uint256(accountant.getState().fixedTermEndTimestamp), 604_699, "the wrapped end timestamp is what the accountant persisted");
    }
}
