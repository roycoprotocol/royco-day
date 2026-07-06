// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";
import { AccountantFuzzHarness } from "./AccountantFuzzHarness.sol";

/**
 * @title AccrualWindowsFuzz
 * @notice Fuzz properties for the premium accrual bookkeeping under interleaved syncs, deposits, and warps:
 *         the time-weighted accumulators integrate the capped yield share over a contiguous window that
 *         starts at the last premium payment, extends to the last sync with no gaps and no double-counting,
 *         and resets exactly when a sync pays the premiums — never on losses, flat syncs, or deposits
 * @dev The model tracks the expected accumulators and timestamps step by step, with each sync's
 *      premiums-paid outcome taken from the independent mirror waterfall rather than from production. The
 *      model lives in contract storage purely to keep stack frames small — every fuzz run starts from a
 *      fresh state, so no data leaks between runs
 */
contract AccrualWindowsFuzz is AccountantFuzzHarness {
    /// @dev The fuzzed constant yield share each mock YDM pins for the whole run
    uint256 internal pinnedJTRate;
    uint256 internal pinnedLTRate;

    /// @dev The expected accrual bookkeeping, carried across the fuzzed steps
    uint256 internal modelTwJT;
    uint256 internal modelTwLT;
    uint256 internal modelLastAccrual;
    uint256 internal modelLastPayment;

    /// @dev The running raw marks the next step moves from
    uint256 internal stRaw;
    uint256 internal jtRaw;
    uint256 internal ltRaw;

    /**
     * Scenario: a seeded market lives through eight fuzzed steps, each an arbitrary warp followed by one of
     * a flat sync, a gain sync, a loss sync, or a senior/junior deposit. The premium a gain sync pays is the
     * senior gain weighted by accumulator / window, so the accounting is only fair if the accumulator covers
     * exactly the window it is divided by: a skipped stretch under-pays the junior and liquidity tranches, a
     * double-counted one over-pays them out of the senior gain, and a reset without a payment silently
     * forfeits accrued premium. After every step the accountant's accumulators and both timestamps must match
     * a step-by-step model, and the accumulator must equal the capped constant share integrated over exactly
     * [last premium payment, last accrual] — the closed form only a contiguous window satisfies.
     */
    function testFuzz_AccrualWindows_contiguousAndResetOnlyWhenPremiumsPay(
        bool _jtCoinvested,
        uint256 _stRaw0,
        uint256 _jtRaw0,
        uint256 _ltRaw0,
        uint256 _jtRate,
        uint256 _ltRate,
        uint256[8] memory _warps,
        uint256[8] memory _actions,
        uint256[8] memory _moves
    )
        public
    {
        _prepareMarket(_jtCoinvested, _stRaw0, _jtRaw0, _ltRaw0, _jtRate, _ltRate);
        for (uint256 i = 0; i < 8; ++i) {
            _step(_warps[i], _actions[i], _moves[i]);
        }
    }

    /// @dev Bounds the seed inputs, deploys the market with the pinned YDM rates, seeds it, and starts the model
    function _prepareMarket(bool _jtCoinvested, uint256 _stRaw0, uint256 _jtRaw0, uint256 _ltRaw0, uint256 _jtRate, uint256 _ltRate) internal {
        stRaw = bound(_stRaw0, 0, MAX_NAV); // full NAV range incl. the empty-tranche edge
        jtRaw = bound(_jtRaw0, 0, MAX_NAV); // full NAV range incl. the uncovered-market edge
        ltRaw = bound(_ltRaw0, 0, MAX_NAV); // full NAV range incl. the no-depth edge
        pinnedJTRate = bound(_jtRate, 0, WAD); // full YDM output range, the accountant caps it at the configured max
        pinnedLTRate = bound(_ltRate, 0, WAD); // full YDM output range, the accountant caps it at the configured max

        _deploy(_jtCoinvested, _defaultParams());
        jtYDM.setRates(pinnedJTRate);
        ltYDM.setRates(pinnedLTRate);
        _seedSymmetric(stRaw, jtRaw, ltRaw);
    }

    /// @dev Warps, dispatches one fuzzed step (sync or deposit), and asserts the window bookkeeping after it
    function _step(uint256 _warp, uint256 _action, uint256 _move) internal {
        // Same-block (0) through a year per step, so windows span multiple syncs and same-block interleavings stay in play
        vm.warp(block.timestamp + bound(_warp, 0, 365 days));
        // Uniform 20% each: flat sync, gain sync, loss sync, senior deposit, junior deposit
        uint256 action = bound(_action, 0, 4);
        if (action == 0) {
            _stepSync(0);
        } else if (action == 1) {
            // Gain of +0.01% to +100%: pays the premiums unless the whole gain recovers impermanent loss
            _stepSync(int256(bound(_move, 1, 10_000)));
        } else if (action == 2) {
            // Loss of -0.01% to -100%: never pays, the accumulators must keep growing
            _stepSync(-int256(bound(_move, 1, 10_000)));
        } else {
            // Deposits run the post-op path, which must leave the accrual bookkeeping completely untouched
            _stepDeposit(action == 3, bound(_move, 1, MAX_NAV));
        }
        _assertWindowBookkeeping();
    }

    /**
     * @dev Runs one pre-op sync moving both raws by the same signed basis points, asserting the sync output
     *      against the mirror driven by the modeled window, then applies the mirror's premiums-paid outcome
     *      to the model: accumulators zero and the payment timestamp advances only when premiums pay
     */
    function _stepSync(int256 _bps) internal {
        uint256 stRawNew = _afterMove(stRaw, _bps);
        uint256 jtRawNew = _afterMove(jtRaw, _bps);
        _modelAccrual();

        // The reset rule: paid premiums close the window, anything else leaves it accruing
        if (_syncAndAssertPayout(stRawNew, jtRawNew)) {
            modelTwJT = 0;
            modelTwLT = 0;
            modelLastPayment = block.timestamp;
        }
        stRaw = stRawNew;
        jtRaw = jtRawNew;
    }

    /**
     * @dev Derives the expected sync output from the modeled window through the independent mirror, executes
     *      the sync plus the liquidity commit, asserts the premium-bearing fields, and returns whether the
     *      mirror says this sync paid the premiums
     */
    function _syncAndAssertPayout(uint256 _stRawNew, uint256 _jtRawNew) internal returns (bool premiumsPaid) {
        RoycoTestMath.WaterfallOut memory out = RoycoTestMath.waterfall(
            _mirrorInput(_stRawNew, _jtRawNew, ltRaw, modelTwJT, modelTwLT, block.timestamp - modelLastPayment, pinnedJTRate, pinnedLTRate)
        );

        SyncedAccountingState memory st = kernel.doPreOp(toNAVUnits(_stRawNew), toNAVUnits(_jtRawNew));
        kernel.doCommit(toNAVUnits(ltRaw));

        // The premiums folded into the effective NAVs tie the accrued window to the sync's actual payout
        assertEq(toUint256(st.stEffectiveNAV), out.stEff, "sync step: senior effective NAV must fold in exactly the modeled premium");
        assertEq(toUint256(st.jtEffectiveNAV), out.jtEff, "sync step: junior effective NAV must fold in exactly the modeled premium");
        assertEq(toUint256(st.ltLiquidityPremium), out.ltLiquidityPremium, "sync step: liquidity premium must come from the modeled window");
        premiumsPaid = out.premiumsPaid;
    }

    /**
     * @dev Models the accrual a sync performs before its waterfall: a first-ever sync initializes both
     *      timestamps and accrues nothing, every later sync extends each accumulator by the capped pinned
     *      share x seconds since the last accrual (a same-block sync extends by nothing)
     */
    function _modelAccrual() internal {
        if (modelLastAccrual == 0) {
            modelLastAccrual = block.timestamp;
            modelLastPayment = block.timestamp;
        } else if (block.timestamp > modelLastAccrual) {
            modelTwJT += Math.min(pinnedJTRate, DEFAULT_MAX_JT_YIELD_SHARE_WAD) * (block.timestamp - modelLastAccrual);
            modelTwLT += Math.min(pinnedLTRate, DEFAULT_MAX_LT_YIELD_SHARE_WAD) * (block.timestamp - modelLastAccrual);
            modelLastAccrual = block.timestamp;
        }
    }

    /// @dev Runs one post-op deposit through the kernel passthrough, which must not touch the accrual bookkeeping
    function _stepDeposit(bool _seniorSide, uint256 _add) internal {
        Operation op;
        if (_seniorSide) {
            op = Operation.ST_DEPOSIT;
            stRaw += _add;
        } else {
            op = Operation.JT_DEPOSIT;
            jtRaw += _add;
        }
        kernel.doPostOp(op, toNAVUnits(stRaw), toNAVUnits(jtRaw), toNAVUnits(ltRaw), ZERO_NAV_UNITS, false);
    }

    /// @dev Asserts the accountant's window bookkeeping equals the model and satisfies the contiguity closed form
    function _assertWindowBookkeeping() internal view {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(uint256(s.twJTYieldShareAccruedWAD), modelTwJT, "window: junior accumulator diverged from the step model");
        assertEq(uint256(s.twLTYieldShareAccruedWAD), modelTwLT, "window: liquidity accumulator diverged from the step model");
        assertEq(uint256(s.lastYieldShareAccrualTimestamp), modelLastAccrual, "window: last accrual timestamp diverged from the step model");
        assertEq(uint256(s.lastPremiumPaymentTimestamp), modelLastPayment, "window: last premium payment timestamp diverged from the step model");

        // Contiguity closed form: with a constant pinned share, an accumulator equals the capped share
        // integrated over exactly [lastPayment, lastAccrual]. A skipped stretch reads low, a double-counted
        // one reads high, and a reset without a payment breaks the window start
        uint256 window = uint256(s.lastYieldShareAccrualTimestamp) - uint256(s.lastPremiumPaymentTimestamp);
        assertEq(
            uint256(s.twJTYieldShareAccruedWAD),
            Math.min(pinnedJTRate, DEFAULT_MAX_JT_YIELD_SHARE_WAD) * window,
            "window: junior accumulator != capped share x contiguous window"
        );
        assertEq(
            uint256(s.twLTYieldShareAccruedWAD),
            Math.min(pinnedLTRate, DEFAULT_MAX_LT_YIELD_SHARE_WAD) * window,
            "window: liquidity accumulator != capped share x contiguous window"
        );
    }
}
