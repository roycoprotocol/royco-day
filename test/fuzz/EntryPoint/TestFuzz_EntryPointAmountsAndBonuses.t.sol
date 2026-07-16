// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";

/**
 * @title TestFuzz_EntryPointAmountsAndBonuses
 * @notice Fuzzes the entry point's conservation properties over request amounts and executor bonus rates: escrow
 *         accounting balances exactly, third-party bonus splits conserve the total claims, and a flat queued
 *         request is economically identical to a direct tranche interaction
 */
contract TestFuzz_EntryPointAmountsAndBonuses is EntryPointTestBase {
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        _seedMarket(1000 * stUnit, 500 * stUnit);
        _deployEntryPoint();
    }

    /// @notice A flat queued deposit mints exactly what a direct tranche deposit of the same amount mints
    function testFuzz_flatQueuedDeposit_equalsDirectDeposit(uint256 _assets) public {
        _assets = bound(_assets, 1e6, 100 * stUnit);

        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), _assets, USER_A, 0);
        _warpPastDepositDelay();
        uint256 queuedShares = _executeDepositMax(USER_A, USER_A, nonce);

        uint256 directShares = _acquireTrancheShares(USER_B, address(juniorTranche), _assets);
        assertEq(queuedShares, directShares, "a flat queued deposit must mint exactly the direct-deposit shares");
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)), 0, "a flat queue must forfeit nothing");
    }

    /// @notice Third-party deposit execution conserves escrow: bonus assets + deposited assets == requested assets
    function testFuzz_thirdPartyDeposit_bonusConservation(uint256 _assets, uint64 _bonusWAD) public {
        _assets = bound(_assets, 1e6, 100 * stUnit);
        // The request-time validation enforces strictly-below-100% bonuses
        _bonusWAD = uint64(bound(_bonusWAD, 0, 1e18 - 1));

        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), _assets, USER_A, _bonusWAD);
        _warpPastDepositDelay();

        uint256 executorBefore = stJtVault.balanceOf(EXECUTOR);
        uint256 escrowBefore = stJtVault.balanceOf(address(entryPoint));
        _executeDepositMax(EXECUTOR, USER_A, nonce);

        uint256 bonusPaid = stJtVault.balanceOf(EXECUTOR) - executorBefore;
        assertEq(bonusPaid, (_assets * _bonusWAD) / 1e18, "the bonus must be the flooring fraction of the executed assets");
        assertEq(escrowBefore - stJtVault.balanceOf(address(entryPoint)), _assets, "the full escrow must leave the entry point");
    }

    /// @notice Third-party redemption execution conserves claims: executor slice + receiver slice == total delivered
    function testFuzz_thirdPartyRedemption_claimConservation(uint256 _assets, uint64 _bonusWAD) public {
        _assets = bound(_assets, 1e6, 100 * stUnit);
        _bonusWAD = uint64(bound(_bonusWAD, 0, 1e18 - 1));

        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), _assets);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_B, _bonusWAD);
        _warpPastRedemptionDelay();

        uint256 executorBefore = stJtVault.balanceOf(EXECUTOR);
        uint256 receiverBefore = stJtVault.balanceOf(USER_B);
        AssetClaims memory userClaims = _executeRedemptionMax(EXECUTOR, USER_A, nonce);

        uint256 executorDelta = stJtVault.balanceOf(EXECUTOR) - executorBefore;
        uint256 receiverDelta = stJtVault.balanceOf(USER_B) - receiverBefore;
        assertEq(receiverDelta, toUint256(userClaims.stAssets) + toUint256(userClaims.jtAssets), "the receiver must get exactly the reported user claims");
        assertEq(stJtVault.balanceOf(address(entryPoint)), 0, "no claim assets may remain in the entry point");
        // The executor's slice is the flooring bonus fraction of the total delivered (2 wei tolerance: one floor per leg)
        assertApproxEqAbs(executorDelta, ((executorDelta + receiverDelta) * _bonusWAD) / 1e18, 2, "the bonus split must conserve the total claims");
    }

    /// @notice Escrow accounting is exact for any partial execution amount
    function testFuzz_partialDepositExecution_escrowAccounting(uint256 _assets, uint256 _slice) public {
        _assets = bound(_assets, 1e6, 100 * stUnit);
        _slice = bound(_slice, 1, _assets);

        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), _assets, USER_A, 0);
        _warpPastDepositDelay();
        _executeDeposit(USER_A, USER_A, nonce, _slice);

        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, nonce).assets), _assets - _slice, "the remaining escrow must be tracked exactly");
        assertEq(stJtVault.balanceOf(address(entryPoint)), _assets - _slice, "the entry point's asset balance must equal the remaining escrow");
    }

    /// @notice Cancellation always returns exactly the unexecuted escrow, for any partial execution prefix
    function testFuzz_cancelAfterPartial_returnsExactRemainder(uint256 _assets, uint256 _slice) public {
        _assets = bound(_assets, 1e6, 100 * stUnit);
        _slice = bound(_slice, 1, _assets - 1);

        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), _assets, USER_A, 0);
        _warpPastDepositDelay();
        _executeDeposit(USER_A, USER_A, nonce, _slice);

        uint256 balanceBefore = stJtVault.balanceOf(USER_A);
        _cancelDeposit(USER_A, nonce, USER_A);
        assertEq(stJtVault.balanceOf(USER_A) - balanceBefore, _assets - _slice, "the cancel must return exactly the unexecuted remainder");
    }
}
