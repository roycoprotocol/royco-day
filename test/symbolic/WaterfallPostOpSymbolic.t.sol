// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { ZERO_NAV_UNITS } from "../../src/libraries/Constants.sol";
import { MarketState, Operation, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { WaterfallSyncDriver } from "../mocks/WaterfallSyncDriver.sol";

/**
 * @title WaterfallPostOpSymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the accountant's post-operation sync: the three
 *         deposit arms book exactly the raw inflow into the operated tranche's effective NAV with no premiums
 *         or fees, the senior-side redemption arms split the self-liquidation bonus between the junior and
 *         senior effective NAVs and revert whenever the bonus exceeds either the junior buffer or the total
 *         redeemed value, a junior redemption scales the coverage impermanent loss ledger down pro-rata with a
 *         floor, and every redemption path rejects a positive raw NAV delta on the senior or junior pool
 * @dev The test contract deploys the sync driver with itself wired as the market's kernel, so every check
 *      enters the post-op entrypoint directly through the kernel gate (and the revert-characterization checks
 *      wrap that same kernel-sender call in try/catch). Checkpoints are seeded straight into the accountant's
 *      ERC-7201 storage and always satisfy the committed conservation identity (raw sum equals effective sum,
 *      enforced at every commit), with cross-tranche claims allowed since every post-op arm is linear
 * @dev The coverage and liquidity minimums are seeded zero so both utilization metrics short-circuit to zero
 *      without touching their ceil-rounded divisions, and the requirement-enforcement flag is passed false:
 *      the gate wiring over the utilization metrics is boolean plumbing owned by the concrete boundary tests,
 *      so the arithmetic under proof here is exactly the post-op NAV bookkeeping. Expected values are plain
 *      checked arithmetic on the bounded domain (NAVs up to 1e30 NAV wei, products cap near 2e60, far below
 *      2^256), never a re-run of the production mulDiv path
 */
contract WaterfallPostOpSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei (one trillion tokens at WAD precision)
    uint256 internal constant MAX_NAV = 1e30;

    WaterfallSyncDriver internal driver;

    function setUp() public {
        // The test contract is the kernel: post-op entry and its try/catch twins both call with the kernel as sender
        driver = new WaterfallSyncDriver(address(this), false);
    }

    /*//////////////////////////////////////////////////////////////////////
                            CHECKPOINT SEEDING
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Seeds a conserved checkpoint with cross-tranche claims allowed: the junior effective NAV is derived
     *      as the conservation residual (raw sum minus the senior effective NAV), which is exactly the envelope
     *      of committable states since conservation is enforced at every commit. The market is perpetual with
     *      zero coverage and liquidity minimums (both utilization metrics short-circuit to zero) and a
     *      liquidation threshold far above any reachable utilization
     */
    function _conservedSeed(
        uint256 _stRaw,
        uint256 _jtRaw,
        uint256 _stEff,
        uint256 _ltRaw
    )
        internal
        pure
        returns (IRoycoDayAccountant.RoycoDayAccountantState memory seed)
    {
        seed.lastMarketState = MarketState.PERPETUAL;
        seed.coverageLiquidationUtilizationWAD = 2e18;
        seed.lastSTRawNAV = toNAVUnits(_stRaw);
        seed.lastJTRawNAV = toNAVUnits(_jtRaw);
        seed.lastSTEffectiveNAV = toNAVUnits(_stEff);
        seed.lastJTEffectiveNAV = toNAVUnits(_stRaw + _jtRaw - _stEff);
        seed.lastLTRawNAV = toNAVUnits(_ltRaw);
    }

    /// @dev Try/catch twin of the post-op entrypoint, surfacing any revert (shape require, checked-sub panic,
    ///      signed-wrap guard, or conservation violation) as a false success flag
    function _tryPostOp(
        Operation _op,
        uint256 _stRawNAV,
        uint256 _jtRawNAV,
        uint256 _ltRawNAV,
        uint256 _bonus
    )
        internal
        returns (bool success)
    {
        try driver.postOpSyncTrancheAccounting(
            _op, toNAVUnits(_stRawNAV), toNAVUnits(_jtRawNAV), toNAVUnits(_ltRawNAV), toNAVUnits(_bonus), false
        ) returns (SyncedAccountingState memory) {
            return true;
        } catch {
            return false;
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                    DEPOSIT ARMS BOOK THE EXACT RAW INFLOW
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A senior deposit books exactly the raw NAV inflow into the senior effective NAV: the junior
     *         effective NAV, the coverage impermanent loss ledger, and the liquidity mark are untouched, the
     *         conservation identity holds on the outputs, and no premium or fee is charged on the flow
     * @dev Economic why: a deposit is new outside capital, not PnL, so it must credit the depositing tranche
     *      one-to-one. Booking a wei more would mint the depositor a claim on other holders' value, a wei less
     *      would donate the depositor's capital to them, and any premium or fee here would tax a flow that
     *      produced no yield. The expected form is a pure addition: effective NAV grows by exactly the raw
     *      delta the kernel observed, which is also what makes the post-op conservation require pass
     */
    function check_seniorDepositBooksExactRawInflowIntoSeniorEffectiveNAV(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 ltRaw,
        uint256 inflow,
        uint256 il
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && ltRaw <= MAX_NAV);
        // Cross-tranche claims allowed: senior may claim any slice of the combined raw sum
        vm.assume(stEff <= stRaw + jtRaw);
        vm.assume(1 <= inflow && inflow <= MAX_NAV);
        vm.assume(il <= MAX_NAV);
        uint256 jtEff = stRaw + jtRaw - stEff;

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _conservedSeed(stRaw, jtRaw, stEff, ltRaw);
        seed.lastJTCoverageImpermanentLoss = toNAVUnits(il);
        driver.seedCheckpoint(seed);

        // The senior pool grows by exactly the inflow, the junior and liquidity marks are flat
        SyncedAccountingState memory state = driver.postOpSyncTrancheAccounting(
            Operation.ST_DEPOSIT, toNAVUnits(stRaw + inflow), toNAVUnits(jtRaw), toNAVUnits(ltRaw), ZERO_NAV_UNITS, false
        );

        // The deposit credits the senior tranche one-to-one and leaves every other claim untouched
        assert(toUint256(state.stEffectiveNAV) == stEff + inflow);
        assert(toUint256(state.jtEffectiveNAV) == jtEff);
        // Conservation restated on the outputs: the fresh raw sum equals the fresh effective sum
        assert((stRaw + inflow) + jtRaw == toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV));
        // The coverage debt ledger passes through unchanged: a deposit neither repays nor creates coverage debt
        assert(toUint256(state.jtCoverageImpermanentLoss) == il);
        // No yield was produced by the flow, so no premium accrues and no fee is taken
        assert(toUint256(state.ltLiquidityPremium) == 0);
        assert(toUint256(state.stProtocolFee) == 0 && toUint256(state.jtProtocolFee) == 0 && toUint256(state.ltProtocolFee) == 0);
    }

    /**
     * @notice A junior deposit books exactly the raw NAV inflow into the junior effective NAV: the senior
     *         effective NAV is untouched, the conservation identity holds on the outputs, and no premium or
     *         fee is charged on the flow
     * @dev Economic why: junior deposits are new first-loss buffer, not yield, so they must grow the junior
     *      claim one-to-one. Any leak into the senior effective NAV would let seniors capture junior principal
     *      the moment it arrives, and any shortfall would dilute the depositing junior against incumbents
     */
    function check_juniorDepositBooksExactRawInflowIntoJuniorEffectiveNAV(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 ltRaw,
        uint256 inflow
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && ltRaw <= MAX_NAV);
        vm.assume(stEff <= stRaw + jtRaw);
        vm.assume(1 <= inflow && inflow <= MAX_NAV);
        uint256 jtEff = stRaw + jtRaw - stEff;

        driver.seedCheckpoint(_conservedSeed(stRaw, jtRaw, stEff, ltRaw));

        // The junior pool grows by exactly the inflow, the senior and liquidity marks are flat
        SyncedAccountingState memory state = driver.postOpSyncTrancheAccounting(
            Operation.JT_DEPOSIT, toNAVUnits(stRaw), toNAVUnits(jtRaw + inflow), toNAVUnits(ltRaw), ZERO_NAV_UNITS, false
        );

        // The deposit credits the junior tranche one-to-one and the senior claim is exactly flat
        assert(toUint256(state.jtEffectiveNAV) == jtEff + inflow);
        assert(toUint256(state.stEffectiveNAV) == stEff);
        // Conservation restated on the outputs
        assert(stRaw + (jtRaw + inflow) == toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV));
        // No yield was produced by the flow, so no premium accrues and no fee is taken
        assert(toUint256(state.ltLiquidityPremium) == 0);
        assert(toUint256(state.stProtocolFee) == 0 && toUint256(state.jtProtocolFee) == 0 && toUint256(state.ltProtocolFee) == 0);
    }

    /**
     * @notice A liquidity tranche deposit commits the fresh liquidity mark and books any senior-leg raw inflow
     *         (the senior shares a multi-asset deposit mints on the way into the pool) one-to-one into the
     *         senior effective NAV, leaving the junior claim exactly flat
     * @dev Economic why: a multi-asset liquidity deposit mints senior shares and pairs them into the pool
     *      inside one operation, so the senior pool can legitimately grow during it. That growth is a fresh
     *      senior deposit in disguise and must be booked like one, one-to-one into the senior effective NAV,
     *      or the minted shares would be claims backed by nothing. The liquidity mark itself is a third,
     *      unconserved leg: it is committed as observed and never enters the two-term conservation identity
     */
    function check_liquidityDepositBooksSeniorLegInflowAndCommitsFreshLiquidityMark(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 ltRaw,
        uint256 ltInflow,
        uint256 stLegInflow
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && ltRaw <= MAX_NAV);
        vm.assume(stEff <= stRaw + jtRaw);
        // The liquidity mark must strictly grow; the senior leg is optional (zero for a pure BPT deposit)
        vm.assume(1 <= ltInflow && ltInflow <= MAX_NAV);
        vm.assume(stLegInflow <= MAX_NAV);
        uint256 jtEff = stRaw + jtRaw - stEff;

        driver.seedCheckpoint(_conservedSeed(stRaw, jtRaw, stEff, ltRaw));

        SyncedAccountingState memory state = driver.postOpSyncTrancheAccounting(
            Operation.LT_DEPOSIT, toNAVUnits(stRaw + stLegInflow), toNAVUnits(jtRaw), toNAVUnits(ltRaw + ltInflow), ZERO_NAV_UNITS, false
        );

        // The senior leg minted during the deposit is credited to seniors one-to-one, juniors are flat
        assert(toUint256(state.stEffectiveNAV) == stEff + stLegInflow);
        assert(toUint256(state.jtEffectiveNAV) == jtEff);
        // The fresh liquidity mark is committed exactly as observed
        assert(toUint256(state.ltRawNAV) == ltRaw + ltInflow);
        // Conservation restated on the outputs: the liquidity mark is not a term in the identity
        assert((stRaw + stLegInflow) + jtRaw == toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV));
        // No yield was produced by the flow, so no premium accrues and no fee is taken
        assert(toUint256(state.ltLiquidityPremium) == 0);
        assert(toUint256(state.stProtocolFee) == 0 && toUint256(state.jtProtocolFee) == 0 && toUint256(state.ltProtocolFee) == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
            SENIOR-SIDE REDEMPTIONS SPLIT THE SELF-LIQUIDATION BONUS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A senior redemption splits the redeemed value between the two effective NAVs by the
     *         self-liquidation bonus: the junior claim pays exactly the bonus, the senior claim pays exactly
     *         the remainder of the total redeemed value, and conservation holds on the outputs
     * @dev Economic why: past the liquidation threshold a redeeming senior is made whole partly out of the
     *      junior buffer (the bonus is realized coverage), so the junior effective NAV must shrink by exactly
     *      the bonus and the senior effective NAV by exactly everything else. A wei of the bonus left with
     *      juniors would double-charge the remaining seniors, a wei over would burn junior buffer that no
     *      redemption consumed. The total redeemed value is derived from both raw pool deltas because the
     *      kernel may source a senior exit from either pool
     */
    function check_seniorRedeemSplitsSelfLiquidationBonusBetweenJuniorAndSenior(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 ltRaw,
        uint256 stOut,
        uint256 jtOut,
        uint256 bonus
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && ltRaw <= MAX_NAV);
        vm.assume(stEff <= stRaw + jtRaw);
        uint256 jtEff = stRaw + jtRaw - stEff;
        // Each pool can only pay out what it holds, and something must actually be redeemed
        vm.assume(stOut <= stRaw && jtOut <= jtRaw);
        uint256 total = stOut + jtOut;
        vm.assume(total >= 1);
        // The bonus is junior buffer actually consumed: within the junior claim and within the redeemed value,
        // and the senior claim can absorb its share, so the success arm of the split is pinned
        vm.assume(bonus <= jtEff && bonus <= total && total - bonus <= stEff);

        driver.seedCheckpoint(_conservedSeed(stRaw, jtRaw, stEff, ltRaw));

        // Senior redemption: the liquidity mark must be exactly flat
        SyncedAccountingState memory state = driver.postOpSyncTrancheAccounting(
            Operation.ST_REDEEM, toNAVUnits(stRaw - stOut), toNAVUnits(jtRaw - jtOut), toNAVUnits(ltRaw), toNAVUnits(bonus), false
        );

        // The junior buffer pays exactly the bonus, the senior claim pays exactly the rest
        assert(toUint256(state.jtEffectiveNAV) == jtEff - bonus);
        assert(toUint256(state.stEffectiveNAV) == stEff - (total - bonus));
        // Conservation restated on the outputs: the redeemed value left both sides of the identity equally
        assert((stRaw - stOut) + (jtRaw - jtOut) == toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV));
        // A redemption produces no yield: no premium, no fees
        assert(toUint256(state.ltLiquidityPremium) == 0);
        assert(toUint256(state.stProtocolFee) == 0 && toUint256(state.jtProtocolFee) == 0 && toUint256(state.ltProtocolFee) == 0);
    }

    /**
     * @notice A liquidity tranche redemption that unwinds a senior leg applies the identical bonus split as a
     *         senior redemption: the junior claim pays exactly the bonus, the senior claim pays the remainder
     *         of the unwound value, and the shrunk liquidity mark is committed as observed
     * @dev Economic why: the multi-asset liquidity redemption burns pool depth and unwinds its senior leg back
     *      to underlying, which is economically a senior exit and must settle senior-side claims identically,
     *      or routing an exit through the liquidity tranche would change who pays for it. The liquidity mark
     *      strictly shrinks here (the redeemed pool slice), pinning the depth-reducing arm of the shape check
     */
    function check_liquidityRedeemSplitsSelfLiquidationBonusBetweenJuniorAndSenior(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 ltRaw,
        uint256 ltOut,
        uint256 stOut,
        uint256 jtOut,
        uint256 bonus
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && ltRaw <= MAX_NAV);
        vm.assume(stEff <= stRaw + jtRaw);
        uint256 jtEff = stRaw + jtRaw - stEff;
        // The redemption removes real pool depth, so the liquidity mark strictly shrinks
        vm.assume(1 <= ltOut && ltOut <= ltRaw);
        vm.assume(stOut <= stRaw && jtOut <= jtRaw);
        uint256 total = stOut + jtOut;
        vm.assume(total >= 1);
        vm.assume(bonus <= jtEff && bonus <= total && total - bonus <= stEff);

        driver.seedCheckpoint(_conservedSeed(stRaw, jtRaw, stEff, ltRaw));

        SyncedAccountingState memory state = driver.postOpSyncTrancheAccounting(
            Operation.LT_REDEEM, toNAVUnits(stRaw - stOut), toNAVUnits(jtRaw - jtOut), toNAVUnits(ltRaw - ltOut), toNAVUnits(bonus), false
        );

        // The identical split a senior redemption gets: bonus from juniors, remainder from seniors
        assert(toUint256(state.jtEffectiveNAV) == jtEff - bonus);
        assert(toUint256(state.stEffectiveNAV) == stEff - (total - bonus));
        // The shrunk liquidity mark is committed exactly as observed
        assert(toUint256(state.ltRawNAV) == ltRaw - ltOut);
        // Conservation restated on the outputs
        assert((stRaw - stOut) + (jtRaw - jtOut) == toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV));
        // A redemption produces no yield: no premium, no fees
        assert(toUint256(state.ltLiquidityPremium) == 0);
        assert(toUint256(state.stProtocolFee) == 0 && toUint256(state.jtProtocolFee) == 0 && toUint256(state.ltProtocolFee) == 0);
    }

    /**
     * @notice A senior redemption whose self-liquidation bonus exceeds the junior effective NAV always
     *         reverts: the junior buffer cannot pay out more coverage than it holds
     * @dev Economic why: the bonus is junior buffer consumed on behalf of the exiting senior. Charging the
     *      junior claim below zero would mint negative junior value, so the checked subtraction of the bonus
     *      from the junior effective NAV must fail before anything is committed. The redemption shape itself
     *      is kept valid (flat liquidity mark, positive redeemed value within each pool) so the only violation
     *      in scope is the oversized bonus
     */
    function check_seniorRedeemRevertsWhenBonusExceedsJuniorEffectiveNAV(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 ltRaw,
        uint256 stOut,
        uint256 jtOut,
        uint256 bonus
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && ltRaw <= MAX_NAV);
        vm.assume(stEff <= stRaw + jtRaw);
        uint256 jtEff = stRaw + jtRaw - stEff;
        vm.assume(stOut <= stRaw && jtOut <= jtRaw);
        vm.assume(stOut + jtOut >= 1);
        // The violation under proof: the bonus overdraws the junior buffer (the bound only needs headroom
        // above the largest seedable junior claim of 2 * MAX_NAV, so the domain stays linear)
        vm.assume(jtEff < bonus && bonus <= 3 * MAX_NAV);

        driver.seedCheckpoint(_conservedSeed(stRaw, jtRaw, stEff, ltRaw));

        // The junior-buffer subtraction underflows (a checked-sub panic, raised before any state is written)
        assert(!_tryPostOp(Operation.ST_REDEEM, stRaw - stOut, jtRaw - jtOut, ltRaw, bonus));
    }

    /**
     * @notice A senior redemption whose self-liquidation bonus exceeds the total redeemed value always
     *         reverts: the bonus is a split of the redemption, never an extra payment on top of it
     * @dev Economic why: the senior side pays total minus bonus, so a bonus above the total would flip the
     *      senior charge negative, silently crediting the senior claim on a redemption. The checked
     *      subtraction of the bonus from the total redeemed value must fail instead. The bonus is kept within
     *      the junior buffer so the junior-side subtraction succeeds and the oversized-bonus violation is the
     *      single regime pinned
     */
    function check_seniorRedeemRevertsWhenBonusExceedsTotalRedeemedValue(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 ltRaw,
        uint256 stOut,
        uint256 jtOut,
        uint256 bonus
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && ltRaw <= MAX_NAV);
        vm.assume(stEff <= stRaw + jtRaw);
        uint256 jtEff = stRaw + jtRaw - stEff;
        vm.assume(stOut <= stRaw && jtOut <= jtRaw);
        uint256 total = stOut + jtOut;
        vm.assume(total >= 1);
        // The violation under proof: the bonus exceeds the redeemed value while staying within the junior
        // buffer, so the junior-side charge succeeds and the total-minus-bonus subtraction is what fails
        vm.assume(total < bonus && bonus <= jtEff);

        driver.seedCheckpoint(_conservedSeed(stRaw, jtRaw, stEff, ltRaw));

        // The total-minus-bonus subtraction underflows (a checked-sub panic, raised before any state is written)
        assert(!_tryPostOp(Operation.ST_REDEEM, stRaw - stOut, jtRaw - jtOut, ltRaw, bonus));
    }

    /*//////////////////////////////////////////////////////////////////////
            JUNIOR REDEMPTION REALIZES THE IL LEDGER PRO-RATA
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A junior redemption scales the coverage impermanent loss ledger down by the exact floored
     *         proportion of the junior effective NAV that remains: the retained ledger is
     *         floor(il * (jtEff - total) / jtEff), it never grows, and the flooring rounds the retained
     *         recovery claim down in favor of the senior tranche
     * @dev Economic why: the ledger is the juniors' claim on future senior yield for coverage they already
     *      paid out, and a withdrawing junior realizes its proportional share of that optionality on exit (it
     *      leaves with its slice of the buffer, so it forfeits its slice of the recovery). Scaling by the
     *      post-redemption fraction of the junior claim keeps the per-unit recovery of the remaining juniors
     *      constant, and flooring means the retained ledger is short by at most one wei, a rounding that
     *      favors the seniors who owe the recovery. The expected form is one plain multiply-and-divide, exact
     *      on this domain because il * jtEff caps near 2e60, far below 2^256
     */
    function check_juniorRedemptionRealizesImpermanentLossProRataRoundedDown(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 ltRaw,
        uint256 stOut,
        uint256 jtOut,
        uint256 il
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && ltRaw <= MAX_NAV);
        vm.assume(stEff <= stRaw + jtRaw);
        uint256 jtEff = stRaw + jtRaw - stEff;
        // The junior exit can be sourced from either pool (its own principal plus accrued senior-side claims)
        vm.assume(stOut <= stRaw && jtOut <= jtRaw);
        uint256 total = stOut + jtOut;
        // Something is redeemed and the junior claim can pay it, so the pro-rata arm with a live ledger is pinned
        vm.assume(1 <= total && total <= jtEff);
        vm.assume(1 <= il && il <= MAX_NAV);

        IRoycoDayAccountant.RoycoDayAccountantState memory seed = _conservedSeed(stRaw, jtRaw, stEff, ltRaw);
        seed.lastJTCoverageImpermanentLoss = toNAVUnits(il);
        driver.seedCheckpoint(seed);

        // Junior redemption: flat liquidity mark, no bonus (juniors cannot take a bonus from their own buffer)
        SyncedAccountingState memory state = driver.postOpSyncTrancheAccounting(
            Operation.JT_REDEEM, toNAVUnits(stRaw - stOut), toNAVUnits(jtRaw - jtOut), toNAVUnits(ltRaw), ZERO_NAV_UNITS, false
        );

        // The junior claim pays the whole redemption, the senior claim is exactly flat
        assert(toUint256(state.jtEffectiveNAV) == jtEff - total);
        assert(toUint256(state.stEffectiveNAV) == stEff);
        // The retained ledger is the exactly floored pro-rata slice of what remains of the junior claim,
        // derived independently as a plain multiply-and-divide (exact: products fit comfortably in 2^256)
        uint256 retainedIL = (il * (jtEff - total)) / jtEff;
        assert(toUint256(state.jtCoverageImpermanentLoss) == retainedIL);
        // Realization is monotone: a junior exit can only shrink the outstanding recovery claim
        assert(retainedIL <= il);
        // Conservation restated on the outputs
        assert((stRaw - stOut) + (jtRaw - jtOut) == toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV));
    }

    /*//////////////////////////////////////////////////////////////////////
            REDEMPTION PATHS REJECT ANY POSITIVE RAW INFLOW
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Every redemption path (senior, junior, or liquidity) reverts when the senior pool's raw NAV
     *         grew during the operation: a redemption can never smuggle a senior inflow past the deposit gates
     * @dev Economic why: deposits and redemptions are gated differently (deposits face the coverage and
     *      liquidity requirement checks), so an operation labeled a redemption that actually adds senior
     *      exposure would bypass the deposit-side gates entirely. The redeemed-value computation negates the
     *      raw deltas, and negating a positive senior delta trips the non-negativity guard on the signed NAV
     *      wrap before the redemption shape check is even reached, so the call surfaces that guard's error
     *      rather than the labeled invalid-state error (a known cosmetic pin, not a safety gap). The three
     *      redemption operations share this rejection code path wholesale, so the operation is left symbolic
     *      over exactly those three members
     */
    function check_redeemPathsRevertOnPositiveSeniorRawInflow(
        uint8 opSelector,
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 ltRaw,
        uint256 stInflow,
        uint256 jtOut
    )
        external
    {
        // Any of the three redemption operations: the rejection happens before they branch apart
        vm.assume(
            opSelector == uint8(Operation.ST_REDEEM) || opSelector == uint8(Operation.JT_REDEEM) || opSelector == uint8(Operation.LT_REDEEM)
        );
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && ltRaw <= MAX_NAV);
        vm.assume(stEff <= stRaw + jtRaw);
        // The violation under proof: the senior pool grew during a redemption; the junior side stays outflow-shaped
        vm.assume(1 <= stInflow && stInflow <= MAX_NAV);
        vm.assume(jtOut <= jtRaw);

        driver.seedCheckpoint(_conservedSeed(stRaw, jtRaw, stEff, ltRaw));

        assert(!_tryPostOp(Operation(opSelector), stRaw + stInflow, jtRaw - jtOut, ltRaw, 0));
    }

    /**
     * @notice Every redemption path (senior, junior, or liquidity) reverts when the junior pool's raw NAV
     *         grew during the operation: a redemption can never smuggle a junior inflow either
     * @dev Economic why: the mirror of the senior-inflow rejection. A junior inflow booked through a
     *      redemption would grow the loss-absorption buffer without the junior deposit arm's bookkeeping,
     *      desynchronizing the buffer from the claims minted against it. The same non-negativity guard on the
     *      negated delta rejects the call before the redemption shape check
     */
    function check_redeemPathsRevertOnPositiveJuniorRawInflow(
        uint8 opSelector,
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 ltRaw,
        uint256 jtInflow,
        uint256 stOut
    )
        external
    {
        // Any of the three redemption operations: the rejection happens before they branch apart
        vm.assume(
            opSelector == uint8(Operation.ST_REDEEM) || opSelector == uint8(Operation.JT_REDEEM) || opSelector == uint8(Operation.LT_REDEEM)
        );
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && ltRaw <= MAX_NAV);
        vm.assume(stEff <= stRaw + jtRaw);
        // The violation under proof: the junior pool grew during a redemption; the senior side stays outflow-shaped
        vm.assume(1 <= jtInflow && jtInflow <= MAX_NAV);
        vm.assume(stOut <= stRaw);

        driver.seedCheckpoint(_conservedSeed(stRaw, jtRaw, stEff, ltRaw));

        assert(!_tryPostOp(Operation(opSelector), stRaw - stOut, jtRaw + jtInflow, ltRaw, 0));
    }
}
