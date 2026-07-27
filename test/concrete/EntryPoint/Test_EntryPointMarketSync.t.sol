// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointMarketSync
 * @notice Every state-changing entry point flow synchronizes its market before it does anything, so no flow ever reads
 *         or writes against a mark left behind by whatever operation happened to run last
 * @dev This matters more here than anywhere else in the protocol: the entry point records user intent against one mark
 *      and settles it against a later one, and the forfeiture mechanism is the comparison BETWEEN those two marks. A
 *      stale mark on either side does not merely round badly, it moves value between the depositor and the protocol
 * @dev The property is observed through the accountant's committed checkpoint, never by counting calls: after any of
 *      these flows the market's persisted mark must already reflect PnL that was injected before the call
 */
contract Test_EntryPointMarketSync is EntryPointTestBase {
    uint256 internal stUnit;
    uint256 internal DEPOSIT_AMOUNT;

    function setUp() public {
        MarketParamsConfig memory params = defaultParams();
        params.fixedTermDurationSeconds = 0;
        _deployMarket(cellA(), params);
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
        DEPOSIT_AMOUNT = 10 * stUnit;
    }

    /// @dev The accountant's PERSISTED collateral mark, which only a committed sync advances
    function _committedCollateralNAV() internal view returns (uint256) {
        return toUint256(accountant.getState().lastCollateralNAV);
    }

    /// @dev Moves the collateral price WITHOUT syncing, leaving the committed mark stale by construction
    function _driftPriceWithoutSyncing(int256 _bps) internal returns (uint256 staleMark) {
        staleMark = _committedCollateralNAV();
        // The entry point fixture's applySTPnL deliberately re-syncs; this reaches past it to the raw oracle move so
        // the committed mark is left genuinely behind the live price
        _scaleCollateralOraclePrice(_bps);
        assertEq(_committedCollateralNAV(), staleMark, "the fixture must leave the committed mark stale before the flow runs");
    }

    // ---------------------------------------------------------------------
    // Each state-changing flow commits a sync of its own
    // ---------------------------------------------------------------------

    function test_requestDeposit_syncsTheMarketBeforeSnapshottingItsReference() public {
        uint256 staleMark = _driftPriceWithoutSyncing(500);
        _requestDepositDefault(USER_A, address(juniorTranche), DEPOSIT_AMOUNT);
        assertGt(_committedCollateralNAV(), staleMark, "requesting a deposit must commit a fresh mark first");
    }

    function test_requestRedemption_syncsTheMarketBeforeSnapshottingItsReference() public {
        _acquireTrancheShares(USER_A, address(juniorTranche), DEPOSIT_AMOUNT);
        uint256 staleMark = _driftPriceWithoutSyncing(500);
        _requestRedemption(USER_A, address(juniorTranche), juniorTranche.balanceOf(USER_A), USER_A, DEFAULT_EXECUTOR_BONUS);
        assertGt(_committedCollateralNAV(), staleMark, "requesting a redemption must commit a fresh mark first");
    }

    function test_executeDeposit_syncsTheMarketBeforeSettling() public {
        uint256 amount = DEPOSIT_AMOUNT;
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(juniorTranche), amount);
        _warpPastDepositDelay();

        uint256 staleMark = _driftPriceWithoutSyncing(500);
        _executeDeposit(EXECUTOR, USER_A, nonce, amount);
        assertGt(_committedCollateralNAV(), staleMark, "executing a deposit must commit a fresh mark first");
    }

    /// @dev The redemption also WITHDRAWS collateral, which pulls the mark down. The slice is sized so the 5% gain the
    ///      sync captures (8e18 on a 160e18 mark) exceeds what the withdrawal removes (~1e18), leaving the net move
    ///      upward only if the sync actually ran: without it the mark could only fall
    function test_executeRedemption_syncsTheMarketBeforeSettling() public {
        _acquireTrancheShares(USER_A, address(juniorTranche), DEPOSIT_AMOUNT);
        uint256 shares = juniorTranche.balanceOf(USER_A) / 10;
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, DEFAULT_EXECUTOR_BONUS);
        _warpPastRedemptionDelay();

        uint256 staleMark = _driftPriceWithoutSyncing(500);
        _executeRedemption(EXECUTOR, USER_A, nonce, shares);
        assertGt(_committedCollateralNAV(), staleMark, "executing a redemption must commit a fresh mark first");
    }

    // ---------------------------------------------------------------------
    // The deliberate exception
    // ---------------------------------------------------------------------

    /**
     * @notice Cancellation does NOT sync, and must not: it is the escape hatch that has to stay reachable when the
     *         market cannot be synced at all
     * @dev Syncing reverts on a paused kernel, a stale oracle, or a tripped sequencer. Were cancellation to sync, those
     *      are exactly the conditions under which a user's escrowed assets would become unrecoverable. Cancellation
     *      also touches no accounting: it returns escrow the entry point already holds, so there is no mark to read
     */
    function test_cancelDeposit_doesNotSyncAndStaysReachableOnAHaltedMarket() public {
        uint256 amount = DEPOSIT_AMOUNT;
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(juniorTranche), amount);

        uint256 staleMark = _driftPriceWithoutSyncing(500);
        uint256 balanceBefore = IERC20(juniorTranche.asset()).balanceOf(USER_A);

        _cancelDeposit(USER_A, nonce, USER_A);
        assertEq(_committedCollateralNAV(), staleMark, "cancelling must not commit a sync of its own");
        assertEq(IERC20(juniorTranche.asset()).balanceOf(USER_A) - balanceBefore, amount, "the escrow must be returned in full");
    }

    /// @notice And it stays reachable with the kernel paused, the state in which a sync could not succeed at all
    function test_cancelDeposit_survivesAPausedKernel() public {
        uint256 amount = DEPOSIT_AMOUNT;
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(juniorTranche), amount);

        vm.prank(PAUSER);
        kernel.pause();

        uint256 balanceBefore = IERC20(juniorTranche.asset()).balanceOf(USER_A);
        _cancelDeposit(USER_A, nonce, USER_A);
        assertEq(IERC20(juniorTranche.asset()).balanceOf(USER_A) - balanceBefore, amount, "a paused market must never strand escrowed assets");
    }
}

