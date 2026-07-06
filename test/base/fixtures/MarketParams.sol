// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { MAX_PROTOCOL_FEE_WAD } from "../../../src/libraries/Constants.sol";
import { MarketParamsConfig } from "./FixtureTypes.sol";

/**
 * @title MarketParams
 * @notice Canonical MarketParamsConfig presets for the parameterized market fixture (testing-strategy.md §2.2)
 * @dev No-frozen-parameters sweep map (testing-strategy.md §2.2). Every field must be exercised at more than one
 *      value somewhere in the suite, CI greps this checklist for totality. Format: field | mandated sweep set | test file
 *
 *      SWEEP-MAP:
 *      minCoverageWAD                     | {0, 0.1e18, WAD-1}                          | test/unit/accountant/CoverageConfigSweep.t.sol (Phase B)
 *      coverageLiquidationUtilizationWAD  | {WAD+1, 1.0009e18, 5e18}                    | test/unit/accountant/LiquidationThresholdSweep.t.sol (Phase B)
 *      minLiquidityWAD                    | {0, 0.05e18, WAD-1}                         | test/unit/accountant/LiquiditySweep.t.sol (Phase B, 0 = I21 reduction)
 *      jtCoinvested                       | {true, false}                               | kernel layer pinned true (RoycoDayKernel.sol:122), false at test/accountant harness (Phase B)
 *      maxJTYieldShareWAD                 | {0, sum == WAD exactly}                     | test/unit/accountant/YieldShareCapSweep.t.sol (Phase B)
 *      maxLTYieldShareWAD                 | {0, sum == WAD exactly}                     | test/unit/accountant/YieldShareCapSweep.t.sol (Phase B)
 *      stProtocolFeeWAD                   | {0, 0.1e18, MAX_PROTOCOL_FEE_WAD}           | test/unit/accountant/FeeSweep.t.sol (Phase B)
 *      jtProtocolFeeWAD                   | {0, 0.1e18, MAX_PROTOCOL_FEE_WAD}           | test/unit/accountant/FeeSweep.t.sol (Phase B)
 *      jtYieldShareProtocolFeeWAD         | {0, 0.1e18, MAX_PROTOCOL_FEE_WAD}           | test/unit/accountant/FeeSweep.t.sol (Phase B)
 *      ltYieldShareProtocolFeeWAD         | {0, 0.1e18, MAX_PROTOCOL_FEE_WAD}           | test/unit/accountant/FeeSweep.t.sol (Phase B)
 *      fixedTermDurationSeconds           | {0, 1 hours, 2 weeks}                       | test/unit/accountant/FixedTermSweep.t.sol (Phase B)
 *      stNAVDustTolerance                 | {0, 1, 1e12}                                | test/unit/accountant/DustToleranceSweep.t.sol (Phase B)
 *      jtNAVDustTolerance                 | {0, 1, 1e12}                                | test/unit/accountant/DustToleranceSweep.t.sol (Phase B)
 *      stSelfLiquidationBonusWAD          | {0, 0.01e18}                                | test/unit/kernel/SelfLiquidationSweep.t.sol (Phase B)
 *      maxReinvestmentSlippageWAD         | {0, 0.001e18, WAD-1}                        | test/unit/kernel/ReinvestGateSweep.t.sol (Phase B)
 *      enforceWhitelistOnTransfer         | {false, true}                               | test/unit/tranches/TransferWhitelist.t.sol (Phase B)
 *      jtYdmKind / ltYdmKind              | {0 Mock, 1 Static, 2 AdaptiveV2}            | test/unit/ydm/YdmKindSweep.t.sol (Phase B)
 *      targetUtilizationWAD               | {0.5e18, 0.9e18}                            | test/unit/ydm/YdmKindSweep.t.sol (Phase B)
 */

/**
 * @notice The default market parameterization used by the smoke suites and any test that does not sweep a field
 * @dev jtCoinvested is true, the kernel family requires it for identical ST/JT assets (RoycoDayKernel.sol:122)
 * @dev YDM kinds default to MockYDM (0) so premiums are pinned constants, the curve target value curve[1] is the
 *      pinned share the fixture programs into each MockYDM, keeping kinds 0/1/2 interchangeable at target utilization
 */
function defaultParams() pure returns (MarketParamsConfig memory) {
    return MarketParamsConfig({
        // coverage / liquidity
        minCoverageWAD: 0.2e18,
        coverageLiquidationUtilizationWAD: 6.4667e18,
        minLiquidityWAD: 0.05e18,
        jtCoinvested: true,
        // premiums
        maxJTYieldShareWAD: 0.5e18,
        maxLTYieldShareWAD: 0.3e18,
        // fees
        stProtocolFeeWAD: 0.1e18,
        jtProtocolFeeWAD: 0.1e18,
        jtYieldShareProtocolFeeWAD: 0.1e18,
        ltYieldShareProtocolFeeWAD: 0.1e18,
        // state machine / dust
        fixedTermDurationSeconds: 2 weeks,
        stNAVDustTolerance: 1,
        jtNAVDustTolerance: 1,
        // kernel
        stSelfLiquidationBonusWAD: 0.01e18,
        maxReinvestmentSlippageWAD: 0.001e18,
        enforceWhitelistOnTransfer: false,
        // ydm wiring
        jtYdmKind: 0,
        ltYdmKind: 0,
        jtCurve: [uint64(0.05e18), uint64(0.2e18), uint64(0.5e18)],
        ltCurve: [uint64(0.02e18), uint64(0.1e18), uint64(0.3e18)],
        targetUtilizationWAD: 0.9e18
    });
}

/**
 * @notice The I21 reduction market, zero minimum liquidity and zero LT yield share
 * @dev A Day market at zero minimum liquidity must behave like a plain ST/JT market (CLAUDE.md P1 acceptance)
 */
function zeroLiquidityParams() pure returns (MarketParamsConfig memory) {
    MarketParamsConfig memory p = defaultParams();
    p.minLiquidityWAD = 0;
    p.maxLTYieldShareWAD = 0;
    p.ltCurve = [uint64(0), uint64(0), uint64(0)];
    return p;
}

/// @notice Every protocol fee at MAX_PROTOCOL_FEE_WAD (100%), probing the zero-residual and fee-share-mint edges
function maxFeeParams() pure returns (MarketParamsConfig memory) {
    MarketParamsConfig memory p = defaultParams();
    p.stProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
    p.jtProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
    p.jtYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
    p.ltYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
    return p;
}

/// @notice A short one-hour fixed term for fast FIXED_TERM entry/exit transition tests
function fixedTermParams() pure returns (MarketParamsConfig memory) {
    MarketParamsConfig memory p = defaultParams();
    p.fixedTermDurationSeconds = 1 hours;
    return p;
}
