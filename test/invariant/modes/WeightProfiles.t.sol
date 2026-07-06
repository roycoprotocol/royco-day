// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DayMarketInvariants } from "../DayMarketInvariants.t.sol";
import { DayMarketHandler } from "../handlers/DayMarketHandler.sol";

/**
 * @title WeightedModeInvariants
 * @notice Shared base for the market-regime invariant profiles, same handler and invariants as the default
 *         suite, different op weights so each run lingers in one regime instead of averaging across all of them
 * @dev The default suite's mixed weighting visits every regime briefly. These profiles re-weight the same
 *      handler selectors so the fuzzer spends a whole run inside one regime (steady flows, sustained stress,
 *      or the liquidation wind-down), which is where regime-specific bugs hide from a mixed schedule
 */
abstract contract WeightedModeInvariants is DayMarketInvariants {
    function setUp() public override {
        handler = _deployHandler();
        handler.init();
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: _modeSelectors() }));
    }

    /// @dev The profile's op mix, weighted by duplicating selectors exactly like the default suite
    function _modeSelectors() internal pure virtual returns (bytes4[] memory);
}

/**
 * @title CalmMarketInvariants
 * @notice A healthy, flow-dominated market: deposits, redemptions, reinvestments, and time passing dominate,
 *         with only occasional small rate moves and a clean venue throughout
 * @dev This regime maximizes successful executions of every production flow (including both multi-asset LT
 *      flows and the premium mint-and-reinvest loop), so share pricing, claim scaling, and the premium
 *      carve-outs get the deepest coverage of states where the gates are far from binding
 */
contract CalmMarketInvariants is WeightedModeInvariants {
    function _modeSelectors() internal pure override returns (bytes4[] memory sels) {
        bytes4[24] memory weighted = [
            DayMarketHandler.op_stDeposit.selector,
            DayMarketHandler.op_stDeposit.selector,
            DayMarketHandler.op_stDeposit.selector,
            DayMarketHandler.op_stRedeem.selector,
            DayMarketHandler.op_stRedeem.selector,
            DayMarketHandler.op_jtDeposit.selector,
            DayMarketHandler.op_jtDeposit.selector,
            DayMarketHandler.op_jtRedeem.selector,
            DayMarketHandler.op_ltDeposit.selector,
            DayMarketHandler.op_ltDeposit.selector,
            DayMarketHandler.op_ltDepositMultiAsset.selector,
            DayMarketHandler.op_ltDepositMultiAsset.selector,
            DayMarketHandler.op_ltRedeem.selector,
            DayMarketHandler.op_ltRedeem.selector,
            DayMarketHandler.op_ltRedeemMultiAsset.selector,
            DayMarketHandler.op_sync.selector,
            DayMarketHandler.op_reinvest.selector,
            DayMarketHandler.op_reinvest.selector,
            DayMarketHandler.op_warp.selector,
            DayMarketHandler.op_warp.selector,
            DayMarketHandler.op_warp.selector,
            DayMarketHandler.op_stPnL.selector,
            DayMarketHandler.op_ltPnL.selector,
            DayMarketHandler.aimed_depositExactlyMaxST.selector
        ];
        sels = new bytes4[](weighted.length);
        for (uint256 i; i < weighted.length; ++i) {
            sels[i] = weighted[i];
        }
    }
}

/**
 * @title StressedMarketInvariants
 * @notice A market under sustained stress: rate moves on every feed dominate, the venue's slippage flaps so
 *         premium repeatedly stages and deploys, and external pool activity drifts the composition
 * @dev This regime concentrates on the waterfall's loss and recovery arms, the coverage-loss ledger, the
 *      staged-premium buffer under a hostile venue, and pool marks that move underneath the liquidity gate,
 *      while a thin stream of flows keeps every gate prediction exercised against the shifting state
 */
contract StressedMarketInvariants is WeightedModeInvariants {
    function _modeSelectors() internal pure override returns (bytes4[] memory sels) {
        bytes4[25] memory weighted = [
            DayMarketHandler.op_stPnL.selector,
            DayMarketHandler.op_stPnL.selector,
            DayMarketHandler.op_stPnL.selector,
            DayMarketHandler.op_jtPnL.selector,
            DayMarketHandler.op_jtPnL.selector,
            DayMarketHandler.op_ltPnL.selector,
            DayMarketHandler.op_ltPnL.selector,
            DayMarketHandler.aimed_coveredDrawdown.selector,
            DayMarketHandler.aimed_coveredDrawdown.selector,
            DayMarketHandler.aimed_toggleVenueSlippage.selector,
            DayMarketHandler.aimed_toggleVenueSlippage.selector,
            DayMarketHandler.op_externalPoolOp.selector,
            DayMarketHandler.op_externalPoolOp.selector,
            DayMarketHandler.op_warp.selector,
            DayMarketHandler.op_warp.selector,
            DayMarketHandler.op_reinvest.selector,
            DayMarketHandler.op_stDeposit.selector,
            DayMarketHandler.op_stRedeem.selector,
            DayMarketHandler.op_jtDeposit.selector,
            DayMarketHandler.op_jtRedeem.selector,
            DayMarketHandler.op_ltDeposit.selector,
            DayMarketHandler.op_ltRedeem.selector,
            DayMarketHandler.op_ltRedeemMultiAsset.selector,
            DayMarketHandler.op_sync.selector,
            DayMarketHandler.op_adminParamNudge.selector
        ];
        sels = new bytes4[](weighted.length);
        for (uint256 i; i < weighted.length; ++i) {
            sels[i] = weighted[i];
        }
    }
}

/**
 * @title LiquidationMarketInvariants
 * @notice A market repeatedly driven to and past the liquidation coverage threshold, then wound down and
 *         recapitalized: closed-form losses to the threshold, full exits, and heavy redemption pressure
 * @dev This regime concentrates on the breached-coverage regime the default mix only touches: the liquidity
 *      gate standing down in liquidation, the senior self-liquidation exit bonus, the coverage-loss erasure
 *      on forced-perpetual transitions, zero-supply edges after full exits, and junior recapitalization
 */
contract LiquidationMarketInvariants is WeightedModeInvariants {
    function _modeSelectors() internal pure override returns (bytes4[] memory sels) {
        bytes4[22] memory weighted = [
            DayMarketHandler.aimed_loseUntilLiquidation.selector,
            DayMarketHandler.aimed_loseUntilLiquidation.selector,
            DayMarketHandler.aimed_loseUntilLiquidation.selector,
            DayMarketHandler.aimed_fullExit.selector,
            DayMarketHandler.aimed_fullExit.selector,
            DayMarketHandler.op_stRedeem.selector,
            DayMarketHandler.op_stRedeem.selector,
            DayMarketHandler.op_jtRedeem.selector,
            DayMarketHandler.op_jtRedeem.selector,
            DayMarketHandler.op_ltRedeem.selector,
            DayMarketHandler.op_ltRedeem.selector,
            DayMarketHandler.op_ltRedeemMultiAsset.selector,
            DayMarketHandler.op_jtDeposit.selector,
            DayMarketHandler.op_jtDeposit.selector,
            DayMarketHandler.op_stDeposit.selector,
            DayMarketHandler.op_stPnL.selector,
            DayMarketHandler.op_stPnL.selector,
            DayMarketHandler.op_warp.selector,
            DayMarketHandler.op_warp.selector,
            DayMarketHandler.op_sync.selector,
            DayMarketHandler.aimed_coveredDrawdown.selector,
            DayMarketHandler.op_adminParamNudge.selector
        ];
        sels = new bytes4[](weighted.length);
        for (uint256 i; i < weighted.length; ++i) {
            sels[i] = weighted[i];
        }
    }
}
