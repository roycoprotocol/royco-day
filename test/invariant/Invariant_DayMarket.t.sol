// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DayMarketHandler } from "./handlers/DayMarketHandler.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

/**
 * @title Invariant_DayMarket
 * @notice Stateful-invariant suite over a full mock Day market driven by the weighted handler
 * @dev The handler verifies every sync against independent recomputations and records any breach as a
 *      violation string instead of reverting, so a failing sequence is preserved and shrunk by the fuzzer.
 *      The invariant functions assert that no violation was ever recorded and re-derive the always-true
 *      identities (conservation, solvency, the idle liquidity premium reconciliation) directly from live state
 */
contract Invariant_DayMarket is StdInvariant, Test {
    DayMarketHandler internal handler;

    function setUp() public virtual {
        handler = _deployHandler();
        handler.init();
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: _weightedSelectors() }));
    }

    /// @dev The default profile runs the standard market with a five percent liquidity requirement
    function _deployHandler() internal virtual returns (DayMarketHandler) {
        return new DayMarketHandler(false);
    }

    /**
     * @dev The op mix, weighted by duplicating selectors: deposits and redemptions dominate, PnL and time
     *      keep the market moving, and each aimed op appears once so the hard regimes stay reachable
     */
    function _weightedSelectors() internal pure returns (bytes4[] memory sels) {
        bytes4[22] memory weighted = [
            DayMarketHandler.op_stDeposit.selector,
            DayMarketHandler.op_stDeposit.selector,
            DayMarketHandler.op_stRedeem.selector,
            DayMarketHandler.op_stRedeem.selector,
            DayMarketHandler.op_jtDeposit.selector,
            DayMarketHandler.op_jtDeposit.selector,
            DayMarketHandler.op_jtRedeem.selector,
            DayMarketHandler.op_ltDeposit.selector,
            DayMarketHandler.op_ltDepositMultiAsset.selector,
            DayMarketHandler.op_ltRedeem.selector,
            DayMarketHandler.op_ltRedeemMultiAsset.selector,
            DayMarketHandler.op_sync.selector,
            DayMarketHandler.op_reinvest.selector,
            DayMarketHandler.op_warp.selector,
            DayMarketHandler.op_warp.selector,
            DayMarketHandler.op_stPnL.selector,
            DayMarketHandler.op_stPnL.selector,
            DayMarketHandler.op_jtPnL.selector,
            DayMarketHandler.op_ltPnL.selector,
            DayMarketHandler.op_adminParamNudge.selector,
            DayMarketHandler.op_externalPoolOp.selector,
            DayMarketHandler.aimed_toggleVenueSlippage.selector
        ];
        sels = new bytes4[](weighted.length + 5);
        for (uint256 i; i < weighted.length; ++i) {
            sels[i] = weighted[i];
        }
        sels[weighted.length] = DayMarketHandler.aimed_depositExactlyMaxST.selector;
        sels[weighted.length + 1] = DayMarketHandler.aimed_loseUntilLiquidation.selector;
        sels[weighted.length + 2] = DayMarketHandler.aimed_coveredDrawdown.selector;
        sels[weighted.length + 3] = DayMarketHandler.aimed_fullExit.selector;
        sels[weighted.length + 4] = DayMarketHandler.aimed_ltRedeemToLiquidityGateBoundary.selector;
    }

    /**
     * @notice No handler-recorded violation may survive: every sync mirror, gate prediction, ledger
     *         replay, price high-water check, and liveness probe must have held
     * @dev Load-bearing because the handler deliberately swallows breaches into a string instead of
     *      reverting, so this assertion is the only thing that turns a recorded breach into a failure
     */
    function invariant_handlerObservedNoViolations() public view {
        assertEq(handler.ghost_violationCount(), 0, handler.ghost_violation());
    }

    /**
     * @notice The always-true identities re-derived from live state: raw equals effective in total, every
     *         internal ledger is fully token-backed, and the idle liquidity premium reconciles mint,
     *         deploy, and payout
     * @dev Load-bearing because these identities are what make every user claim redeemable: a divergence
     *      means the market's books no longer match the tokens the kernel actually holds
     */
    function invariant_coreIdentitiesHold() public view {
        assertEq(bytes(handler.coreInvariantBreach()).length, 0, handler.coreInvariantBreach());
    }

    /**
     * @notice The two-term NAV conservation identity at wei precision after every op:
     *         stRawNAV + jtRawNAV == stEffectiveNAV + jtEffectiveNAV
     * @dev Load-bearing because the liquidity premium is minted as covered senior shares inside
     *      stEffectiveNAV, never a third NAV leg: if the fee and liquidity premium share mint (or any
     *      sync arm) ever created or destroyed a wei of NAV, this is where it would surface. On a breach
     *      the full committed checkpoint is dumped in the failure message
     */
    function invariant_stRawPlusJtRawEqualsStEffPlusJtEff() public view {
        (bool holds, string memory report) = handler.conservationCheckpointReport();
        assertTrue(holds, report);
    }

    /// @dev Prints which regimes and ops this run actually reached, the anti-vacuity evidence for the run
    function afterInvariant() public view {
        console2.log("syncs verified            ", handler.ghost_syncCount());
        console2.log("fixed term entered        ", handler.ghost_enteredFixedTerm());
        console2.log("fixed term exited         ", handler.ghost_exitedFixedTerm());
        console2.log("liquidation crossed       ", handler.ghost_crossedLiquidationThreshold());
        console2.log("idle liquidity premium observed", handler.ghost_idleLiquidityPremiumObserved());
        console2.log("uncovered loss realized   ", handler.ghost_uncoveredLossRealized());
        console2.log("zero-supply states        ", handler.ghost_zeroSupplyStatesReached());
        console2.log("premium shares minted     ", handler.ghost_liquidityPremiumSharesMinted());
        console2.log("premium shares reinvested ", handler.ghost_liquidityPremiumSharesReinvested());
        console2.log("idle shares paid out      ", handler.ghost_idlePremiumSeniorSharesPaidToRedeemers());
        console2.log("coverage-loss events      ", handler.jtCoverageImpermanentLossEventCount());
        _logOpLedger("stDeposit");
        _logOpLedger("stRedeem");
        _logOpLedger("jtDeposit");
        _logOpLedger("jtRedeem");
        _logOpLedger("ltDeposit");
        _logOpLedger("ltDepositMultiAsset");
        _logOpLedger("ltRedeem");
        _logOpLedger("ltRedeemMultiAsset");
        _logOpLedger("sync");
        _logOpLedger("reinvest");
        _logOpLedger("warp");
        _logOpLedger("stPnL");
        _logOpLedger("jtPnL");
        _logOpLedger("ltPnL");
        _logOpLedger("adminParamNudge");
        _logOpLedger("externalPoolOp");
        _logOpLedger("toggleVenueSlippage");
        _logOpLedger("aimedDepositExactlyMaxST");
        _logOpLedger("aimedLoseUntilLiquidation");
        _logOpLedger("aimedCoveredDrawdown");
        _logOpLedger("aimedFullExit");
        _logOpLedger("aimedLtRedeemToLiquidityGateBoundary");
    }

    /// @dev One line of the per-op anti-vacuity ledger: calls, successes, and predicted gate rejections
    function _logOpLedger(string memory _op) internal view {
        console2.log(
            string.concat("op ", _op, " calls/successes/predicted-rejections"),
            handler.opCalls(_op),
            handler.opSuccesses(_op),
            handler.opPredictedReverts(_op)
        );
    }
}

/**
 * @title Invariant_DayMarketZeroLiquidity
 * @notice The reduction profile: a market with no liquidity requirement and no liquidity premium must run
 *         the identical handler cleanly with the premium machinery provably silent
 */
contract Invariant_DayMarketZeroLiquidity is Invariant_DayMarket {
    function _deployHandler() internal override returns (DayMarketHandler) {
        return new DayMarketHandler(true);
    }

    /**
     * @notice With no liquidity requirement configured, no liquidity premium senior share may ever be
     *         minted, held idle, deployed, or paid out
     * @dev Load-bearing because a zero-minimum-liquidity Day market must reduce to a plain senior/junior
     *      market: any premium activity here means the liquidity overlay leaks into the base engine
     */
    function invariant_liquidityPremiumMachineryStaysSilent() public view {
        assertEq(handler.ghost_liquidityPremiumSharesMinted(), 0, "a zero-liquidity market minted liquidity premium shares");
        assertEq(handler.ghost_idleLiquidityPremiumObserved(), 0, "a zero-liquidity market held idle liquidity premium senior shares");
        assertEq(handler.ghost_liquidityPremiumSharesReinvested(), 0, "a zero-liquidity market reinvested liquidity premium shares");
        assertEq(handler.ghost_idlePremiumSeniorSharesPaidToRedeemers(), 0, "a zero-liquidity market paid idle liquidity premium shares to redeemers");
    }
}
