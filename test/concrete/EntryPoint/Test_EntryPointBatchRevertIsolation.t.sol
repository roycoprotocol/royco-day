// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ADMIN_ENTRY_POINT_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointBatchRevertIsolation
 * @notice Adversarial coverage of the array executors' revert isolation: each request is routed through a
 *         self-delegatecall, so a reverting request must unwind its own writes and nothing else while the rest of the
 *         batch settles normally
 * @dev The self-delegatecall is the load-bearing mechanism. It runs through the ERC1967 proxy (address(this) is the
 *      proxy, whose fallback delegatecalls the implementation), so the hop is a nested delegatecall that must still
 *      preserve msg.sender and operate on the proxy's storage. Every cell below is written to fail loudly if either
 *      property broke: a lost msg.sender would misroute the executor bonus to the entry point and turn self executions
 *      into third-party ones, and a lost storage context would leave the request escrow desynced from the mint
 */
contract Test_EntryPointBatchRevertIsolation is EntryPointTestBase {
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
    }

    // ---------------------------------------------------------------------
    // Batch builders
    // ---------------------------------------------------------------------

    function _depositBatch(
        address[2] memory _users,
        uint256[2] memory _nonces,
        uint256[2] memory _assets
    )
        internal
        pure
        returns (address[] memory users, uint256[] memory nonces, TRANCHE_UNIT[] memory assets)
    {
        users = new address[](2);
        nonces = new uint256[](2);
        assets = new TRANCHE_UNIT[](2);
        for (uint256 i = 0; i < 2; ++i) {
            (users[i], nonces[i], assets[i]) = (_users[i], _nonces[i], toTrancheUnits(_assets[i]));
        }
    }

    // ---------------------------------------------------------------------
    // msg.sender must survive the delegatecall hop
    // ---------------------------------------------------------------------

    /// @notice A third-party batch pays the executor bonus to the caller, never to the entry point: the nested
    ///         delegatecall through the proxy preserves msg.sender, so the bonus recipient and the self-execution test
    ///         both key on the real executor
    function test_batch_preservesMsgSender_payingBonusToTheCaller() public {
        (uint256 nonceA,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, DEFAULT_EXECUTOR_BONUS);
        (uint256 nonceB,) = _requestDeposit(USER_B, address(juniorTranche), 10 * stUnit, USER_B, DEFAULT_EXECUTOR_BONUS);
        _warpPastDepositDelay();

        (address[] memory users, uint256[] memory nonces, TRANCHE_UNIT[] memory assets) =
            _depositBatch([USER_A, USER_B], [nonceA, nonceB], [10 * stUnit, 10 * stUnit]);

        vm.prank(EXECUTOR);
        uint256[] memory minted = entryPoint.executeDeposits(users, nonces, assets);

        // Both executed, and each mint split between its own receiver and the one shared executor
        assertGt(minted[0], 0, "the first request must mint");
        assertGt(minted[1], 0, "the second request must mint");
        uint256 executorBonus = IERC20(address(juniorTranche)).balanceOf(EXECUTOR);
        assertGt(executorBonus, 0, "a third-party batch must pay the executor a bonus");
        assertEq(
            IERC20(address(juniorTranche)).balanceOf(USER_A) + IERC20(address(juniorTranche)).balanceOf(USER_B) + executorBonus,
            minted[0] + minted[1],
            "the batch's mints must split exactly between the receivers and the executor"
        );
        // A lost msg.sender would have made address(this) the executor and stranded the bonus on the entry point
        assertEq(
            IERC20(address(juniorTranche)).balanceOf(address(entryPoint)),
            entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)),
            "the entry point must hold nothing beyond its pending protocol fee shares"
        );
    }

    /// @notice A self-executed batch pays no bonus: msg.sender surviving the hop is what makes _user == executor hold
    function test_batch_preservesMsgSender_selfExecutionPaysNoBonus() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, DEFAULT_EXECUTOR_BONUS);
        (uint256 other,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, DEFAULT_EXECUTOR_BONUS);
        _warpPastDepositDelay();

        (address[] memory users, uint256[] memory nonces, TRANCHE_UNIT[] memory assets) =
            _depositBatch([USER_A, USER_A], [nonce, other], [10 * stUnit, 10 * stUnit]);

        vm.prank(USER_A);
        uint256[] memory minted = entryPoint.executeDeposits(users, nonces, assets);

        assertEq(IERC20(address(juniorTranche)).balanceOf(USER_A), minted[0] + minted[1], "a self-executed batch must leave the whole mint with the user");
        assertEq(IERC20(address(juniorTranche)).balanceOf(EXECUTOR), 0, "a self-executed batch must pay no executor bonus");
    }

    /// @notice The request owner opting out of third-party execution still blocks a batch executor, and only that request
    function test_batch_optedOutRequestIsSkippedNotHonoured() public {
        (uint256 optedOut,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, type(uint64).max);
        (uint256 open,) = _requestDeposit(USER_B, address(juniorTranche), 10 * stUnit, USER_B, DEFAULT_EXECUTOR_BONUS);
        _warpPastDepositDelay();

        (address[] memory users, uint256[] memory nonces, TRANCHE_UNIT[] memory assets) =
            _depositBatch([USER_A, USER_B], [optedOut, open], [10 * stUnit, 10 * stUnit]);

        vm.prank(EXECUTOR);
        uint256[] memory minted = entryPoint.executeDeposits(users, nonces, assets);

        assertEq(minted[0], 0, "the opted-out request must be skipped for a third-party executor");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, optedOut).assets), 10 * stUnit, "the opted-out request's escrow must be intact");
        assertGt(minted[1], 0, "the opted-in request must still execute");
    }

    // ---------------------------------------------------------------------
    // A skipped request must leave zero footprint
    // ---------------------------------------------------------------------

    /// @notice A reverting request writes nothing: no escrow consumed, no shares minted, no protocol fee shares accrued,
    ///         and the entry point's token balance is unchanged by the failed leg
    function test_skippedRequest_leavesNoStateFootprint() public {
        (uint256 good,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        _warpPastDepositDelay();
        // Queued after the warp, so it is still inside its own delay when the batch runs and reverts INVALID_REQUEST
        (uint256 bad,) = _requestDeposit(USER_B, address(juniorTranche), 10 * stUnit, USER_B, 0);

        uint256 feeBefore = entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche));
        uint256 supplyBefore = IERC20(address(juniorTranche)).totalSupply();

        (address[] memory users, uint256[] memory nonces, TRANCHE_UNIT[] memory assets) =
            _depositBatch([USER_A, USER_B], [good, bad], [10 * stUnit, 10 * stUnit]);

        vm.prank(USER_A);
        uint256[] memory minted = entryPoint.executeDeposits(users, nonces, assets);

        assertGt(minted[0], 0, "the matured request must execute");
        assertEq(minted[1], 0, "the unmatured request must be skipped");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_B, bad).assets), 10 * stUnit, "the skipped request's escrow must be untouched");
        assertEq(IERC20(address(juniorTranche)).balanceOf(USER_B), 0, "the skipped request must mint nothing to its receiver");
        assertEq(
            IERC20(address(juniorTranche)).totalSupply() - supplyBefore, minted[0], "only the executed request may expand the supply"
        );
        assertEq(
            IERC20(address(juniorTranche)).balanceOf(address(entryPoint)),
            entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)),
            "the entry point must strand no shares from the skipped leg"
        );
        assertEq(
            entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)),
            feeBefore,
            "a flat queue must accrue no protocol fee shares, skipped or not"
        );
    }

    /// @notice Ordering independence: a reverting request between two good ones blocks neither, in either position
    function test_skippedRequest_doesNotBlockLaterOrEarlierRequests() public {
        (uint256 first,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        (uint256 second,) = _requestDeposit(USER_B, address(juniorTranche), 10 * stUnit, USER_B, 0);
        _warpPastDepositDelay();
        (uint256 bad,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0); // unmatured

        address[] memory users = new address[](3);
        uint256[] memory nonces = new uint256[](3);
        TRANCHE_UNIT[] memory assets = new TRANCHE_UNIT[](3);
        (users[0], nonces[0], assets[0]) = (USER_A, first, toTrancheUnits(10 * stUnit));
        (users[1], nonces[1], assets[1]) = (USER_A, bad, toTrancheUnits(10 * stUnit));
        (users[2], nonces[2], assets[2]) = (USER_B, second, toTrancheUnits(10 * stUnit));

        vm.prank(USER_A);
        uint256[] memory minted = entryPoint.executeDeposits(users, nonces, assets);

        assertGt(minted[0], 0, "the request before the reverting one must execute");
        assertEq(minted[1], 0, "the reverting request must be skipped");
        assertGt(minted[2], 0, "the request after the reverting one must execute");
    }

    // ---------------------------------------------------------------------
    // Replay and duplicate entries
    // ---------------------------------------------------------------------

    /// @notice The same (user, nonce) twice in one batch consumes the request exactly once: the second pass finds the
    ///         deleted request and is skipped rather than double minting
    function test_duplicateEntryInBatch_executesOnce() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        _warpPastDepositDelay();

        (address[] memory users, uint256[] memory nonces, TRANCHE_UNIT[] memory assets) =
            _depositBatch([USER_A, USER_A], [nonce, nonce], [10 * stUnit, 10 * stUnit]);

        vm.prank(USER_A);
        uint256[] memory minted = entryPoint.executeDeposits(users, nonces, assets);

        assertGt(minted[0], 0, "the first pass must consume the request");
        assertEq(minted[1], 0, "the duplicate pass must find nothing left to execute");
        assertEq(IERC20(address(juniorTranche)).balanceOf(USER_A), minted[0], "the duplicate must not double mint to the receiver");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, nonce).assets), 0, "the request must be consumed exactly once");
    }

    /// @notice Two partial slices of one request in a single batch both settle, and the escrow accounting stays exact
    ///         across the delegatecall hops (a lost storage context would desync the remainder)
    function test_duplicatePartialSlicesInBatch_bothSettleExactly() public {
        uint256 amount = 10 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);
        _warpPastDepositDelay();

        (address[] memory users, uint256[] memory nonces, TRANCHE_UNIT[] memory assets) =
            _depositBatch([USER_A, USER_A], [nonce, nonce], [amount / 2, amount / 2]);

        vm.prank(USER_A);
        uint256[] memory minted = entryPoint.executeDeposits(users, nonces, assets);

        assertGt(minted[0], 0, "the first slice must mint");
        assertGt(minted[1], 0, "the second slice must mint");
        assertEq(IERC20(address(juniorTranche)).balanceOf(USER_A), minted[0] + minted[1], "both slices' mints must land on the receiver");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, nonce).assets), 0, "both slices together must consume the whole request");
    }

    // ---------------------------------------------------------------------
    // Redemptions
    // ---------------------------------------------------------------------

    /// @notice The redemption batch isolates a reverting request identically, leaving its escrowed shares recoverable
    function test_redemptionBatch_skipsRevertingRequestAndKeepsSharesRecoverable() public {
        uint256 sharesA = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        uint256 sharesB = _acquireTrancheShares(USER_B, address(juniorTranche), 10 * stUnit);
        (uint256 good,) = _requestRedemption(USER_A, address(juniorTranche), sharesA, USER_A, 0);
        _warpPastRedemptionDelay();
        (uint256 bad,) = _requestRedemption(USER_B, address(juniorTranche), sharesB, USER_B, 0); // unmatured

        address[] memory users = new address[](2);
        uint256[] memory nonces = new uint256[](2);
        uint256[] memory shares = new uint256[](2);
        (users[0], nonces[0], shares[0]) = (USER_A, good, type(uint256).max);
        (users[1], nonces[1], shares[1]) = (USER_B, bad, type(uint256).max);

        vm.prank(USER_A);
        (AssetClaims[] memory claims, uint256[] memory quoteAssets) = entryPoint.executeRedemptions(users, nonces, shares);

        assertGt(toUint256(claims[0].nav), 0, "the matured redemption must settle");
        assertEq(toUint256(claims[1].nav), 0, "the unmatured redemption's claims slot must be zeroed");
        assertEq(quoteAssets[1], 0, "the unmatured redemption's quote slot must be zeroed");
        assertEq(entryPoint.getRedemptionRequest(USER_B, bad).shares, sharesB, "the skipped redemption's escrowed shares must be intact");

        // The escrow is still the user's: cancellation returns every share the skipped request held
        uint256 balBefore = IERC20(address(juniorTranche)).balanceOf(USER_B);
        vm.prank(USER_B);
        entryPoint.cancelRedemptionRequest(bad, USER_B);
        assertEq(IERC20(address(juniorTranche)).balanceOf(USER_B) - balBefore, sharesB, "the skipped redemption must cancel whole");
    }

    // ---------------------------------------------------------------------
    // The single-request executors stay strict
    // ---------------------------------------------------------------------

    /// @notice Revert tolerance is scoped to the array surface: the single-request executors still surface the revert,
    ///         so a caller that wants the error is never silently handed a zero
    function test_singleRequestExecutors_stillRevert() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.INVALID_REQUEST.selector, nonce));
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(10 * stUnit));

        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 redemption,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.INVALID_REQUEST.selector, redemption));
        entryPoint.executeRedemption(USER_A, redemption, type(uint256).max);
    }

    /// @notice The caller-error guard is NOT swallowed: a length mismatch still reverts the whole call, because it is a
    ///         malformed batch rather than an unexecutable request
    function test_arrayLengthMismatch_stillRevertsTheWholeBatch() public {
        address[] memory users = new address[](2);
        uint256[] memory nonces = new uint256[](1);
        TRANCHE_UNIT[] memory assets = new TRANCHE_UNIT[](2);
        vm.prank(USER_A);
        vm.expectRevert(IRoycoDayEntryPoint.ARRAY_LENGTH_MISMATCH.selector);
        entryPoint.executeDeposits(users, nonces, assets);

        uint256[] memory shares = new uint256[](2);
        uint256[] memory shortNonces = new uint256[](1);
        vm.prank(USER_A);
        vm.expectRevert(IRoycoDayEntryPoint.ARRAY_LENGTH_MISMATCH.selector);
        entryPoint.executeRedemptions(users, shortNonces, shares);
    }

    /// @notice The array executor carries no `restricted` of its own, so authorization is governed entirely by the
    ///         binding on the single-request selector it delegatecalls into. Narrowing that binding must narrow the
    ///         batch with it: an unauthorized caller executes nothing while an authorized one still settles everything
    function test_batchAuthorization_isGovernedByTheSingleRequestBinding() public {
        (uint256 nonceA,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, DEFAULT_EXECUTOR_BONUS);
        (uint256 nonceB,) = _requestDeposit(USER_B, address(juniorTranche), 10 * stUnit, USER_B, DEFAULT_EXECUTOR_BONUS);
        _warpPastDepositDelay();

        // Narrow the single-request executor off PUBLIC_ROLE, leaving the array executor's own surface untouched
        accessManager.setTargetFunctionRole(address(entryPoint), _sels(IRoycoDayEntryPoint.executeDeposit.selector), ADMIN_ENTRY_POINT_ROLE);

        (address[] memory users, uint256[] memory nonces, TRANCHE_UNIT[] memory assets) =
            _depositBatch([USER_A, USER_B], [nonceA, nonceB], [10 * stUnit, 10 * stUnit]);

        // An unauthorized caller reaches the array surface but every request is rejected inside its isolating frame
        vm.prank(EXECUTOR);
        uint256[] memory minted = entryPoint.executeDeposits(users, nonces, assets);
        assertEq(minted[0], 0, "an unauthorized batch caller must execute nothing");
        assertEq(minted[1], 0, "an unauthorized batch caller must execute nothing");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, nonceA).assets), 10 * stUnit, "the rejected request's escrow must be intact");

        // The role holder settles the identical batch
        vm.prank(ENTRY_POINT_ADMIN);
        minted = entryPoint.executeDeposits(users, nonces, assets);
        assertGt(minted[0], 0, "the authorized caller must execute the first request");
        assertGt(minted[1], 0, "the authorized caller must execute the second request");
    }

    /// @notice An empty batch is a no-op rather than a revert
    function test_emptyBatch_isANoOp() public {
        address[] memory users = new address[](0);
        uint256[] memory nonces = new uint256[](0);
        TRANCHE_UNIT[] memory assets = new TRANCHE_UNIT[](0);
        vm.prank(USER_A);
        uint256[] memory minted = entryPoint.executeDeposits(users, nonces, assets);
        assertEq(minted.length, 0, "an empty deposit batch must return an empty array");
    }

    /// @notice The pause gate is never bypassed by the hop. The array executors carry no whenNotPaused of their own, so
    ///         a paused entry point does not reject the batch: every request's own gate reverts inside its isolating
    ///         frame and the batch settles nothing, which is the same end state a rejection would leave
    function test_pausedEntryPoint_executesNothing() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        (uint256 other,) = _requestDeposit(USER_B, address(juniorTranche), 10 * stUnit, USER_B, 0);
        _warpPastDepositDelay();
        vm.prank(PAUSER);
        IRoycoAuth(address(entryPoint)).pause();

        (address[] memory users, uint256[] memory nonces, TRANCHE_UNIT[] memory assets) =
            _depositBatch([USER_A, USER_B], [nonce, other], [10 * stUnit, 10 * stUnit]);
        vm.prank(USER_A);
        uint256[] memory minted = entryPoint.executeDeposits(users, nonces, assets);

        assertEq(minted[0], 0, "a paused entry point must mint nothing for the first request");
        assertEq(minted[1], 0, "a paused entry point must mint nothing for the second request");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, nonce).assets), 10 * stUnit, "the first request's escrow must be untouched while paused");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_B, other).assets), 10 * stUnit, "the second request's escrow must be untouched while paused");
        assertEq(IERC20(address(juniorTranche)).balanceOf(USER_A), 0, "a paused batch must mint to nobody");

        // Unpausing restores the batch with both requests still whole
        vm.prank(UNPAUSER);
        IRoycoAuth(address(entryPoint)).unpause();
        vm.prank(USER_A);
        minted = entryPoint.executeDeposits(users, nonces, assets);
        assertGt(minted[0], 0, "the first request must execute once unpaused");
        assertGt(minted[1], 0, "the second request must execute once unpaused");
    }

    /// @notice The single-request executors keep the loud pause: a paused entry point reverts them outright, so a caller
    ///         that needs to distinguish "paused" from "nothing to do" still can
    function test_pausedEntryPoint_singleRequestExecutorStillReverts() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        _warpPastDepositDelay();
        vm.prank(PAUSER);
        IRoycoAuth(address(entryPoint)).pause();

        vm.prank(USER_A);
        vm.expectRevert();
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(10 * stUnit));
    }
}
