// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DayMarketHandler } from "./handlers/DayMarketHandler.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

/**
 * @title DayMarketInvariants
 * @notice Stateful-invariant suite over a full mock Day market driven by the weighted handler
 * @dev The handler verifies every sync against independent recomputations and records any breach as a
 *      violation string instead of reverting, so a failing sequence is preserved and shrunk by the fuzzer.
 *      The invariant functions assert that no violation was ever recorded and re-derive the always-true
 *      identities (conservation, solvency, the staged-premium reconciliation) directly from live state
 */
contract DayMarketInvariants is StdInvariant, Test {
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
        sels = new bytes4[](weighted.length + 4);
        for (uint256 i; i < weighted.length; ++i) {
            sels[i] = weighted[i];
        }
        sels[weighted.length] = DayMarketHandler.aimed_depositExactlyMaxST.selector;
        sels[weighted.length + 1] = DayMarketHandler.aimed_loseUntilLiquidation.selector;
        sels[weighted.length + 2] = DayMarketHandler.aimed_coveredDrawdown.selector;
        sels[weighted.length + 3] = DayMarketHandler.aimed_fullExit.selector;
    }

    /// @notice No handler-recorded violation may survive: every sync mirror, gate prediction, ledger
    ///         replay, price high-water check, and liveness probe must have held
    function invariant_handlerObservedNoViolations() public view {
        assertEq(handler.ghost_violationCount(), 0, handler.ghost_violation());
    }

    /// @notice The always-true identities re-derived from live state: raw equals effective in total, every
    ///         internal ledger is fully token-backed, and the staged premium reconciles mint, deploy, payout
    function invariant_coreIdentitiesHold() public view {
        assertEq(bytes(handler.coreInvariantBreach()).length, 0, handler.coreInvariantBreach());
    }

    /// @dev Prints which regimes this run actually reached, the coverage evidence for the run
    function afterInvariant() public view {
        console2.log("syncs verified            ", handler.ghost_syncCount());
        console2.log("fixed term entered        ", handler.ghost_enteredFixedTerm());
        console2.log("fixed term exited         ", handler.ghost_exitedFixedTerm());
        console2.log("liquidation crossed       ", handler.ghost_crossedLiquidationThreshold());
        console2.log("staged premium observed   ", handler.ghost_stagedPremiumObserved());
        console2.log("uncovered loss realized   ", handler.ghost_uncoveredLossRealized());
        console2.log("zero-supply states        ", handler.ghost_zeroSupplyStatesReached());
        console2.log("premium shares minted     ", handler.ghost_premiumSharesMinted());
        console2.log("premium shares reinvested ", handler.ghost_premiumSharesReinvested());
        console2.log("idle shares paid out      ", handler.ghost_idleSharesPaidToRedeemers());
        console2.log("coverage-loss events      ", handler.ilEventCount());
    }
}

/**
 * @title DayMarketZeroLiquidityInvariants
 * @notice The reduction profile: a market with no liquidity requirement and no liquidity premium must run
 *         the identical handler cleanly with the premium machinery provably silent
 */
contract DayMarketZeroLiquidityInvariants is DayMarketInvariants {
    function _deployHandler() internal override returns (DayMarketHandler) {
        return new DayMarketHandler(true);
    }

    /// @notice With no liquidity requirement configured, no premium share may ever be minted or staged
    function invariant_liquidityPremiumMachineryStaysSilent() public view {
        assertEq(handler.ghost_premiumSharesMinted(), 0, "a zero-liquidity market minted premium shares");
        assertEq(handler.ghost_stagedPremiumObserved(), 0, "a zero-liquidity market staged premium shares");
    }
}
