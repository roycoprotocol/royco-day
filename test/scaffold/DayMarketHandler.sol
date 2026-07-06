// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { TrancheFixture } from "./TrancheFixture.sol";

/**
 * @title DayMarketHandler (SCAFFOLD — Phase D implements this; see docs/testing-strategy.md §3)
 * @notice Stateful-invariant handler skeleton. Encodes the actor set, weighted op surface, ghost
 *         variables, and — critically — the mitigations for the six ways a naive handler fails to
 *         reach interesting states (losses, threshold crossings, FIXED_TERM, staged premium,
 *         zero-supply, silent reverts).
 *
 * Handler rules (docs/testing-strategy.md §3):
 *  - Every op ends with `_afterOp()`: try-sync (I14) + I1/I2/I13/I16 asserts on committed state.
 *  - An op may skip only on a PREDICTED revert (gate recomputed via RoycoTestMath first).
 *    An unpredicted revert fails the run — the anti-early-return rule, applied to handlers.
 */
abstract contract DayMarketHandler is TrancheFixture {
    // ---------------- Actors ----------------
    address[3] internal stActors;
    address[2] internal jtActors;
    address[2] internal ltActors;
    address internal externalLp; // interacts with the Balancer pool directly (hooks path)
    address internal keeper; // sync / reinvest role holder
    address internal admin;

    // ---------------- Ghost variables ----------------
    // I2 solvency ledgers (per asset, NAV-independent raw token units)
    mapping(address token => uint256) internal ghost_transferredIn;
    mapping(address token => uint256) internal ghost_transferredOut;
    // I15 idle-premium conservation ledger (ST-share units)
    uint256 internal ghost_premiumSharesMinted;
    uint256 internal ghost_premiumSharesReinvested;
    uint256 internal ghost_idleSharesPaidToRedeemers;
    // I5 IL event log: signed deltas with cause tags, replayed against committed IL

    enum ILCause {
        COVERAGE_APPLIED,
        RECOVERY,
        JT_REDEEM_SCALE,
        ERASED
    }

    struct ILEvent {
        ILCause cause;
        uint256 magnitude;
    }

    ILEvent[] internal ghost_ilEvents;
    // I13 share-price monotonicity trackers (WAD prices + loss-event flags per tranche)
    uint256 internal ghost_stPriceHighWater;
    uint256 internal ghost_jtPriceHighWater;
    uint256 internal ghost_ltPriceHighWater;
    bool internal ghost_uncoveredLossSinceLastCheck; // permits p_st drop
    bool internal ghost_jtLossSinceLastCheck; // permits p_jt drop
    bool internal ghost_ltVenueLossSinceLastCheck; // permits p_lt drop
    // I19 accrual-window ledger
    uint256 internal ghost_lastPremiumPaymentTs;
    uint256 internal ghost_accruedWindowSeconds;
    // coverage counters proving the forced-regime mitigations actually fired (Phase D exit criteria)
    uint256 internal ghost_enteredFixedTerm;
    uint256 internal ghost_crossedLiquidationThreshold;
    uint256 internal ghost_stagedPremiumObserved;
    uint256 internal ghost_zeroSupplyStatesReached;

    // ---------------- Weighted ops (targetSelector weights in DayMarketInvariants.t.sol) ----------------
    // Weights (docs/testing-strategy.md §3): stDeposit 15, stRedeem 10, jtDeposit 10, jtRedeem 8,
    // ltDeposit 6, ltDepositMultiAsset 6, ltRedeem 6, ltRedeemMultiAsset 6, sync 10, reinvest 4,
    // warp 10, stPnL 8, jtPnL 4, ltPnL 4, adminParamNudge 2, externalPoolOp 1.

    function op_stDeposit(uint256 _actorSeed, uint256 _assets) external virtual;
    function op_stRedeem(uint256 _actorSeed, uint256 _shares) external virtual;
    function op_jtDeposit(uint256 _actorSeed, uint256 _assets) external virtual;
    function op_jtRedeem(uint256 _actorSeed, uint256 _shares) external virtual;
    function op_ltDeposit(uint256 _actorSeed, uint256 _bpt) external virtual;
    function op_ltDepositMultiAsset(uint256 _actorSeed, uint256 _stAssets, uint256 _quote) external virtual;
    function op_ltRedeem(uint256 _actorSeed, uint256 _shares) external virtual;
    function op_ltRedeemMultiAsset(uint256 _actorSeed, uint256 _shares) external virtual;
    function op_sync() external virtual;
    function op_reinvest(uint256 _stShares) external virtual;
    function op_warp(uint256 _seconds) external virtual; // bound to [1s, 30d]
    function op_stPnL(int256 _bps) external virtual; // bound to [-300, 300] bps via mock rate
    function op_jtPnL(int256 _bps) external virtual;
    function op_ltPnL(int256 _bps) external virtual;
    function op_adminParamNudge(uint256 _paramSeed, uint256 _valueSeed) external virtual;
    function op_externalPoolOp(uint256 _kindSeed, uint256 _amount) external virtual; // swap/join/exit via hooks path

    // ---------------- Naive-handler failure-mode mitigations (aimed ops) ----------------
    /// @dev Mitigation #2: deposits exactly maxSTDeposit() so covU/liqU land ON the boundary.
    function aimed_depositExactlyMaxST(uint256 _actorSeed) external virtual;
    /// @dev Mitigation #2: computes (from F7's closed form) and applies the ST rate drop that sets
    ///      covU >= coverageLiquidationUtilizationWAD, then syncs. Increments ghost counter.
    function aimed_loseUntilLiquidation() external virtual;
    /// @dev Mitigation #3: ST loss < jtEffectiveNAV then sync => FIXED_TERM entry. Increments counter.
    function aimed_coveredDrawdown(uint256 _lossBps) external virtual;
    /// @dev Mitigation #4: toggles MockVenue slippage mode so reinvestment alternates pass/fail and
    ///      the idle premium pile actually grows.
    function aimed_toggleVenueSlippage() external virtual;
    /// @dev Mitigation #5: full exit of one tranche to reach zero-supply / empty-vault boundaries.
    function aimed_fullExit(uint256 _trancheSeed) external virtual;

    // ---------------- Post-op checks ----------------
    /// @dev Runs after EVERY op: try-sync (I14: any unpredicted sync revert fails the run), then
    ///      asserts I1 (conservation, from accountant.getState(), not trusting the in-contract require),
    ///      I2 (solvency vs ghost ledgers), I13 (price monotonicity vs high-water marks + loss flags),
    ///      I16 (ltRawNAV excludes idle premium shares).
    function _afterOp() internal virtual;

    /// @dev Predicted-revert helper: recomputes the relevant gate via RoycoTestMath and returns
    ///      whether the op is expected to revert. Ops call this BEFORE executing; a revert without
    ///      prediction (or success despite prediction) is a failure.
    function _predictReverts(uint8 _op, uint256 _actorIdx, uint256 _amount) internal view virtual returns (bool);
}
