// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { MAX_PROTOCOL_FEE_WAD } from "../../src/libraries/Constants.sol";
import { MarketParamsConfig } from "./FixtureTypes.sol";

/**
 * @title MarketParams
 * @notice Canonical MarketParamsConfig presets for the parameterized market fixture
 * @dev No-frozen-parameters sweep map. Every field must be exercised at more than one value somewhere in
 *      the suite (concrete/, fuzz/, or scenarios/ own each axis for their feature); an axis missing its
 *      sweep is a coverage gap, not a waived requirement. Format: field | mandated sweep set
 *
 *      SWEEP-MAP:
 *      minCoverageWAD                     | {0, 0.1e18, WAD-1}
 *      coverageLiquidationUtilizationWAD  | {WAD+1, 1.0009e18, 5e18}
 *      minLiquidityWAD                    | {0, 0.05e18, WAD-1}          (0 = the zero minimum-liquidity market)
 *      maxJTYieldShareWAD                 | {0, sum == WAD exactly}
 *      maxLTYieldShareWAD                 | {0, sum == WAD exactly}
 *      stProtocolFeeWAD                   | {0, 0.1e18, MAX_PROTOCOL_FEE_WAD}
 *      jtProtocolFeeWAD                   | {0, 0.1e18, MAX_PROTOCOL_FEE_WAD}
 *      jtYieldShareProtocolFeeWAD         | {0, 0.1e18, MAX_PROTOCOL_FEE_WAD}
 *      ltYieldShareProtocolFeeWAD         | {0, 0.1e18, MAX_PROTOCOL_FEE_WAD}
 *      fixedTermDurationSeconds           | {0, 1 hours, 2 weeks}
 *      stNAVDustTolerance                 | {0, 1, 1e12}
 *      jtNAVDustTolerance                 | {0, 1, 1e12}
 *      stSelfLiquidationBonusWAD          | {0, 0.01e18}
 *      maxReinvestmentSlippageWAD         | {0, 0.001e18, WAD-1}
 *      enforceWhitelistOnTransfer         | {false, true}
 *      jtYdmKind / ltYdmKind              | {0 Mock, 1 Static, 2 AdaptiveV2}
 *      targetUtilizationWAD               | {0.5e18, 0.9e18}
 */

/**
 * @notice The default market parameterization used by the market lifecycle suites and any test that does not sweep a field
 * @dev YDM kinds default to MockYDM (0) so premiums are pinned constants, the curve target value curve[1] is the
 *      pinned share the fixture programs into each MockYDM, keeping kinds 0/1/2 interchangeable at target utilization
 */
function defaultParams() pure returns (MarketParamsConfig memory) {
    return MarketParamsConfig({
        // coverage / liquidity
        minCoverageWAD: 0.2e18,
        coverageLiquidationUtilizationWAD: 6.4667e18,
        minLiquidityWAD: 0.05e18,
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
 * @notice The zero minimum-liquidity market (minLiquidityWAD == 0), with zero LT yield share
 * @dev A Day market at zero minimum liquidity must behave exactly like a plain ST/JT market, the core
 *      property the LT overlay promises, so this preset backs Invariant_ReductionEquivalence
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
