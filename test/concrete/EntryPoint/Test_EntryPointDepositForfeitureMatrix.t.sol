// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { TrancheType } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointDepositForfeitureMatrix
 * @notice The full hand-derived deposit share-forfeiture matrix: {ST gain, JT loss, LPT underperformance} x
 *         {self-execution, third-party executor bonus} x {single-shot, two partial slices}, with each tranche's
 *         no-forfeiture control. Every expected number is derived independently in-test (RoycoTestMath's unclamped
 *         virtual-shares mirror over raw kernel/tranche state reads), never read back from src accounting
 * @dev The forfeiture directions: a deposit forfeits exactly when the tranche's share price FALLS during the queue
 *      (the same request-time value mints more shares at execution). The capped SENIOR underperforms the collateral
 *      on a gain; the levered JUNIOR falls harder than the collateral on a loss; the LIQUIDITY PROVIDER tranche
 *      underperforms its own BPT deposit-value reference when a staged idle senior-share premium dilutes a BPT gain
 * @dev The market runs with fixedTermDurationSeconds == 0 so the JT-loss cells stay PERPETUAL (a nonzero term would
 *      lock FIXED_TERM on the covered drawdown and gate the deposit execution the cell needs)
 * @dev Partition invariants pinned per cell (all exact):
 *          storedRef   == unclamped((S + 1e6) * depositValue / (N + 1))     [request time]
 *          userShares  == min(storedRef, sharesExec)
 *          forfeited   == sharesExec - userShares
 *          bonusShares == floor(userShares * bonusWAD / 1e18)               [per executed slice]
 *          receiver    == userShares - bonusShares
 *          EP balance  == protocol fee shares pending collection (nothing stranded)
 */
contract Test_EntryPointDepositForfeitureMatrix is EntryPointTestBase {
    uint256 internal stUnit;

    function setUp() public {
        // Zero fixed-term duration: covered drawdowns stay PERPETUAL so the JT-loss cells remain executable
        MarketParamsConfig memory params = defaultParams();
        params.fixedTermDurationSeconds = 0;
        _deployMarket(cellA(), params);
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
        _stageIdlePremium();
    }

    /// @dev Stages an idle liquidity premium (armed venue slippage fails the reinvest gate, so the premium is held as
    ///      idle senior shares): the LPT-underperformance cells need the idle leg to dilute a BPT gain
    function _stageIdlePremium() internal {
        setVenueSlippageMode(true);
        applySTPnL(1000);
        _sync();
        assertGt(kernel.getState().lptOwnedSeniorTrancheShares, 0, "the fixture must stage an idle senior-share premium");
    }

    // ---------------------------------------------------------------------
    // Independent derivations
    // ---------------------------------------------------------------------

    /// @dev Independently derives the entry point's request-time share reference: the deposit's kernel-priced value
    ///      over the tranche's totalAssets-implied share price at the UNCLAMPED fair virtual-shares rate
    function _derivedDepositReference(address _tranche, uint256 _assets) internal view returns (uint256 shares) {
        NAV_UNIT depositValue = (entryPoint.getTrancheConfig(_tranche).trancheType == TrancheType.LIQUIDITY_PROVIDER)
            ? kernel.convertLPTAssetsToValue(toTrancheUnits(_assets))
            : kernel.convertCollateralAssetsToValue(toTrancheUnits(_assets));
        return RoycoTestMath.convertToSharesUnclamped(
            toUint256(depositValue), toUint256(IRoycoVaultTranche(_tranche).totalAssets().nav), IERC20(_tranche).totalSupply()
        );
    }

    /// @dev Ensures the senior liquidity bound cannot gate the cell's deposit: the ST cells run on top of the staged
    ///      premium's +10% and the cell's own +10%, so extra quote-only LPT depth is seeded ahead of the request
    function _ensureCellCapacity(address _tranche, uint256 _amount) internal {
        if (_tranche == address(seniorTranche)) _ensureLiquidityCapacityForSTDeposit(3 * _amount);
    }

    /// @dev Applies the adverse (forfeiture-triggering) PnL for the tranche's cell
    function _applyAdversePnL(address _tranche) internal {
        if (_tranche == address(seniorTranche)) applySTPnL(1000); // capped senior underperforms the collateral gain
        else if (_tranche == address(juniorTranche)) applySTPnL(-1000); // levered junior falls harder than the collateral
        else applyLPTPnL(1000); // the staged idle premium dilutes the BPT gain, so the LPT share price rises less
    }

    /// @dev Applies the favorable (no-forfeiture) PnL for the tranche's control
    function _applyFavorablePnL(address _tranche) internal {
        if (_tranche == address(seniorTranche)) applySTPnL(-500); // covered loss: ST NAV held whole while the deposit value falls
        else if (_tranche == address(juniorTranche)) applySTPnL(1000); // levered junior outperforms the collateral gain
        else applyLPTPnL(-1000); // the idle leg cushions the BPT loss, so the LPT share price falls less than the deposit value
    }

    // ---------------------------------------------------------------------
    // Cell runners
    // ---------------------------------------------------------------------

    /// @dev Locals for a matrix cell (struct-packed against stack depth)
    struct Cell {
        uint256 amount;
        uint256 nonce;
        uint256 storedRef;
        address executor;
        uint256 feeBefore;
        uint256 sharesExec1;
        uint256 sharesExec2;
        uint256 userShares1;
        uint256 userShares2;
        uint256 refLeft;
        uint256 refFilled1;
        uint256 expectedBonus;
    }

    /// @dev Runs a single-shot cell: request, adverse PnL, one MAX execution, exact partition asserts
    function _runSingleShotCell(address _tranche, uint64 _bonusWAD) internal {
        Cell memory c;
        c.amount = (_tranche == address(liquidityProviderTranche)) ? 10e18 : 10 * stUnit;
        c.executor = (_bonusWAD == 0) ? USER_A : EXECUTOR;

        _ensureCellCapacity(_tranche, c.amount);
        (c.nonce,) = _requestDeposit(USER_A, _tranche, c.amount, USER_A, _bonusWAD);
        c.storedRef = entryPoint.getDepositRequest(USER_A, c.nonce).equivalentSharesAtRequestTime;
        assertEq(c.storedRef, _derivedDepositReference(_tranche, c.amount), "the stored reference must equal the independently derived unclamped share count");

        _applyAdversePnL(_tranche);
        _warpPastDepositDelay();

        // The full escrow is deposited on every path (the bonus is a share slice, never an asset deduction)
        c.sharesExec1 = IRoycoVaultTranche(_tranche).previewDeposit(toTrancheUnits(c.amount));
        c.feeBefore = entryPoint.getProtocolFeeSharesPendingCollection(_tranche);
        c.userShares1 = _executeDepositMax(c.executor, USER_A, c.nonce);

        // The partition: the user keeps the lower leg of the min, the excess is forfeited, and the split is exact
        assertGt(c.sharesExec1, c.storedRef, "sanity: the adverse move must make execution mint more than the reference");
        assertEq(c.userShares1, Math.min(c.storedRef, c.sharesExec1), "the user's mint must be pinned to the request-time share reference");
        uint256 forfeited = entryPoint.getProtocolFeeSharesPendingCollection(_tranche) - c.feeBefore;
        assertGt(forfeited, 0, "the adverse cell must forfeit a nonzero excess");
        assertEq(c.userShares1 + forfeited, c.sharesExec1, "the minted shares must split exactly into the user's pin and the forfeited excess");

        // The bonus is a flooring share slice of the post-forfeiture mint; the receiver keeps the remainder
        c.expectedBonus = (_bonusWAD == 0) ? 0 : Math.mulDiv(c.userShares1, _bonusWAD, 1e18, Math.Rounding.Floor);
        if (_bonusWAD != 0) assertEq(IERC20(_tranche).balanceOf(EXECUTOR), c.expectedBonus, "the executor must receive the flooring share slice of the user's mint");
        assertEq(IERC20(_tranche).balanceOf(USER_A), c.userShares1 - c.expectedBonus, "the receiver must keep the remainder of the user's mint");
        // Nothing stranded: the entry point holds exactly the forfeited fee shares
        assertEq(
            IERC20(_tranche).balanceOf(address(entryPoint)),
            entryPoint.getProtocolFeeSharesPendingCollection(_tranche),
            "the entry point must hold exactly the pending protocol fee shares"
        );
        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, c.nonce).assets), 0, "the request must be fully consumed");
    }

    /// @dev Runs a two-slice cell: request, adverse PnL, an explicit half then a MAX remainder, per-slice partitions
    function _runSplitCell(address _tranche, uint64 _bonusWAD) internal {
        Cell memory c;
        c.amount = (_tranche == address(liquidityProviderTranche)) ? 10e18 : 10 * stUnit;
        c.executor = (_bonusWAD == 0) ? USER_A : EXECUTOR;

        _ensureCellCapacity(_tranche, c.amount);
        (c.nonce,) = _requestDeposit(USER_A, _tranche, c.amount, USER_A, _bonusWAD);
        c.storedRef = entryPoint.getDepositRequest(USER_A, c.nonce).equivalentSharesAtRequestTime;
        assertEq(c.storedRef, _derivedDepositReference(_tranche, c.amount), "the stored reference must equal the independently derived unclamped share count");

        _applyAdversePnL(_tranche);
        _warpPastDepositDelay();

        // Slice 1 (explicit half): the pro-rata storage rescale floors the unfilled half's reference into storage,
        // leaving the ceil remainder as the filled portion's reference
        uint256 slice = c.amount / 2;
        c.refLeft = Math.mulDiv(c.storedRef, c.amount - slice, c.amount, Math.Rounding.Floor);
        c.refFilled1 = c.storedRef - c.refLeft;
        c.sharesExec1 = IRoycoVaultTranche(_tranche).previewDeposit(toTrancheUnits(slice));
        c.feeBefore = entryPoint.getProtocolFeeSharesPendingCollection(_tranche);
        c.userShares1 = _executeDeposit(c.executor, USER_A, c.nonce, slice);
        assertEq(c.userShares1, Math.min(c.refFilled1, c.sharesExec1), "slice 1 must be pinned to its pro-rata reference portion");
        assertEq(
            entryPoint.getDepositRequest(USER_A, c.nonce).equivalentSharesAtRequestTime,
            c.refLeft,
            "the unfilled remainder's reference must persist as the floor-scaled portion"
        );

        // Slice 2 (MAX remainder): the whole stored remainder is the filled portion's reference; slice 1's deposit
        // shifted pricing, so its execution mint is previewed after slice 1 lands
        c.sharesExec2 = IRoycoVaultTranche(_tranche).previewDeposit(toTrancheUnits(c.amount - slice));
        c.userShares2 = _executeDepositMax(c.executor, USER_A, c.nonce);
        assertEq(c.userShares2, Math.min(c.refLeft, c.sharesExec2), "slice 2 must be pinned to the stored remainder reference");

        // Whole-request partition: both slices' excesses land as protocol fee shares
        uint256 forfeited = entryPoint.getProtocolFeeSharesPendingCollection(_tranche) - c.feeBefore;
        assertGt(forfeited, 0, "the adverse split cell must forfeit a nonzero excess");
        assertEq(c.userShares1 + c.userShares2 + forfeited, c.sharesExec1 + c.sharesExec2, "the two slices' mints must split exactly into user pins and forfeited excess");

        // The bonus floors per slice off each slice's post-forfeiture mint
        c.expectedBonus = (_bonusWAD == 0)
            ? 0
            : Math.mulDiv(c.userShares1, _bonusWAD, 1e18, Math.Rounding.Floor) + Math.mulDiv(c.userShares2, _bonusWAD, 1e18, Math.Rounding.Floor);
        if (_bonusWAD != 0) assertEq(IERC20(_tranche).balanceOf(EXECUTOR), c.expectedBonus, "the executor must receive each slice's flooring share slice");
        assertEq(IERC20(_tranche).balanceOf(USER_A), c.userShares1 + c.userShares2 - c.expectedBonus, "the receiver must keep the remainder of both slices' mints");
        assertEq(
            IERC20(_tranche).balanceOf(address(entryPoint)),
            entryPoint.getProtocolFeeSharesPendingCollection(_tranche),
            "the entry point must hold exactly the pending protocol fee shares"
        );
    }

    /// @dev Runs a no-forfeiture control: favorable PnL leaves the execution mint at or below the reference
    function _runControlCell(address _tranche) internal {
        uint256 amount = (_tranche == address(liquidityProviderTranche)) ? 10e18 : 10 * stUnit;
        _ensureCellCapacity(_tranche, amount);
        (uint256 nonce,) = _requestDeposit(USER_A, _tranche, amount, USER_A, 0);
        uint256 storedRef = entryPoint.getDepositRequest(USER_A, nonce).equivalentSharesAtRequestTime;

        _applyFavorablePnL(_tranche);
        _warpPastDepositDelay();

        uint256 sharesExec = IRoycoVaultTranche(_tranche).previewDeposit(toTrancheUnits(amount));
        uint256 feeBefore = entryPoint.getProtocolFeeSharesPendingCollection(_tranche);
        uint256 userShares = _executeDepositMax(USER_A, USER_A, nonce);

        assertLe(sharesExec, storedRef, "sanity: the favorable move must not make execution mint more than the reference");
        assertEq(userShares, sharesExec, "with no excess the user must keep the whole execution mint");
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(_tranche), feeBefore, "a favorable queue must forfeit nothing");
        assertEq(IERC20(_tranche).balanceOf(USER_A), userShares, "the whole mint must land on the receiver");
    }

    // ---------------------------------------------------------------------
    // The matrix: SENIOR (capped, forfeits on a collateral gain)
    // ---------------------------------------------------------------------

    function test_depositMatrix_stGain_self_singleShot() public {
        _runSingleShotCell(address(seniorTranche), 0);
    }

    function test_depositMatrix_stGain_self_partialSlices() public {
        _runSplitCell(address(seniorTranche), 0);
    }

    function test_depositMatrix_stGain_bonus_singleShot() public {
        _runSingleShotCell(address(seniorTranche), DEFAULT_EXECUTOR_BONUS);
    }

    function test_depositMatrix_stGain_bonus_partialSlices() public {
        _runSplitCell(address(seniorTranche), DEFAULT_EXECUTOR_BONUS);
    }

    function test_depositMatrix_stCoveredLoss_noForfeitureControl() public {
        _runControlCell(address(seniorTranche));
    }

    // ---------------------------------------------------------------------
    // The matrix: JUNIOR (levered, forfeits on a collateral loss)
    // ---------------------------------------------------------------------

    function test_depositMatrix_jtLoss_self_singleShot() public {
        _runSingleShotCell(address(juniorTranche), 0);
    }

    function test_depositMatrix_jtLoss_self_partialSlices() public {
        _runSplitCell(address(juniorTranche), 0);
    }

    function test_depositMatrix_jtLoss_bonus_singleShot() public {
        _runSingleShotCell(address(juniorTranche), DEFAULT_EXECUTOR_BONUS);
    }

    function test_depositMatrix_jtLoss_bonus_partialSlices() public {
        _runSplitCell(address(juniorTranche), DEFAULT_EXECUTOR_BONUS);
    }

    function test_depositMatrix_jtGain_noForfeitureControl() public {
        _runControlCell(address(juniorTranche));
    }

    // ---------------------------------------------------------------------
    // The matrix: LIQUIDITY PROVIDER (idle premium dilutes a BPT gain, forfeits on BPT appreciation)
    // ---------------------------------------------------------------------

    function test_depositMatrix_lptUnderperformance_self_singleShot() public {
        _runSingleShotCell(address(liquidityProviderTranche), 0);
    }

    function test_depositMatrix_lptUnderperformance_self_partialSlices() public {
        _runSplitCell(address(liquidityProviderTranche), 0);
    }

    function test_depositMatrix_lptUnderperformance_bonus_singleShot() public {
        _runSingleShotCell(address(liquidityProviderTranche), DEFAULT_EXECUTOR_BONUS);
    }

    function test_depositMatrix_lptUnderperformance_bonus_partialSlices() public {
        _runSplitCell(address(liquidityProviderTranche), DEFAULT_EXECUTOR_BONUS);
    }

    function test_depositMatrix_lptBptLoss_noForfeitureControl() public {
        _runControlCell(address(liquidityProviderTranche));
    }
}
