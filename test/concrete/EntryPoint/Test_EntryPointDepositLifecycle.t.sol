// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { stdError } from "../../../lib/forge-std/src/StdError.sol";
import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase, IERC20Like } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointDepositLifecycle
 * @notice The deposit half of the entry point's request/execute/cancel lifecycle across all three tranches:
 *         escrow accounting, delay enforcement, self vs third-party execution with bonuses, partial execution,
 *         MAX-sentinel capping, cancellation, and batch semantics
 */
contract Test_EntryPointDepositLifecycle is EntryPointTestBase {
    uint256 internal stUnit;
    uint256 internal quoteUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
    }

    /// @dev Deposit amount sized so ST's coverage/liquidity gates never bind in the seeded market
    function _depositAmount(address _tranche) internal view returns (uint256) {
        return _tranche == address(liquidityTranche) ? 10e18 : 10 * stUnit;
    }

    function _tranches() internal view returns (address[3] memory) {
        return [address(seniorTranche), address(juniorTranche), address(liquidityTranche)];
    }

    // ---------------------------------------------------------------------
    // requestDeposit
    // ---------------------------------------------------------------------

    function test_requestDeposit_escrowsAssetsAndRegistersRequest_allTranches() public {
        address[3] memory tranches = _tranches();
        for (uint256 i = 0; i < 3; ++i) {
            address tranche = tranches[i];
            uint256 amount = _depositAmount(tranche);
            address asset = address(entryPoint.getTrancheConfig(tranche).asset);
            uint256 escrowBefore = IERC20Like(asset).balanceOf(address(entryPoint));

            (uint256 nonce, uint32 executableAt) = _requestDepositDefault(USER_A, tranche, amount);

            assertEq(IERC20Like(asset).balanceOf(address(entryPoint)) - escrowBefore, amount, "assets must be escrowed in the entry point");
            IRoycoDayEntryPoint.DepositRequest memory request = entryPoint.getDepositRequest(USER_A, nonce);
            assertEq(request.assets, toTrancheUnits(amount), "request assets");
            assertEq(request.baseRequest.tranche, tranche, "request tranche");
            assertEq(request.baseRequest.receiver, USER_A, "request receiver");
            assertEq(request.baseRequest.executableAtTimestamp, executableAt, "request executableAt");
            assertEq(executableAt, uint32(block.timestamp + DEFAULT_DEPOSIT_DELAY), "executableAt must be now + deposit delay");
            assertGt(toUint256(request.baseRequest.navAtRequestTime), 0, "the nav snapshot must be taken on every request");
        }
    }

    function test_requestDeposit_incrementsGlobalNonce() public {
        (uint256 nonce1,) = _requestDepositDefault(USER_A, address(seniorTranche), _depositAmount(address(seniorTranche)));
        (uint256 nonce2,) = _requestDepositDefault(USER_B, address(juniorTranche), _depositAmount(address(juniorTranche)));
        assertEq(nonce2, nonce1 + 1, "nonces must be globally monotonic");
        assertEq(entryPoint.getLastRequestNonce(), nonce2, "getLastRequestNonce must track the last assigned nonce");
    }

    function test_requestDeposit_maxBonusSentinel_optsOutOfThirdPartyExecution() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), _depositAmount(address(juniorTranche)), USER_A, type(uint64).max);
        _warpPastDepositDelay();
        vm.expectRevert(IRoycoDayEntryPoint.THIRD_PARTY_EXECUTION_DISABLED.selector);
        vm.prank(EXECUTOR);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));
        // Self execution still works
        uint256 shares = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(shares, 0, "self execution must succeed after the opt-out");
    }

    function test_requestDeposit_revertsOnZeroAmount() public {
        vm.expectRevert(IRoycoDayEntryPoint.MUST_EXECUTE_NON_ZERO_AMOUNT.selector);
        vm.prank(USER_A);
        entryPoint.requestDeposit(address(seniorTranche), toTrancheUnits(0), USER_A, 0);
    }

    function test_requestDeposit_revertsOnNullTrancheOrReceiver() public {
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        vm.prank(USER_A);
        entryPoint.requestDeposit(address(0), toTrancheUnits(1), USER_A, 0);

        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        vm.prank(USER_A);
        entryPoint.requestDeposit(address(seniorTranche), toTrancheUnits(1), address(0), 0);
    }

    function test_requestDeposit_revertsOnInvalidBonus() public {
        // The bonus must be strictly less than 100%: at exactly WAD the deposit remainder would be zero
        vm.expectRevert(IRoycoDayEntryPoint.INVALID_EXECUTOR_BONUS.selector);
        vm.prank(USER_A);
        entryPoint.requestDeposit(address(seniorTranche), toTrancheUnits(1), USER_A, uint64(1e18));

        vm.expectRevert(IRoycoDayEntryPoint.INVALID_EXECUTOR_BONUS.selector);
        vm.prank(USER_A);
        entryPoint.requestDeposit(address(seniorTranche), toTrancheUnits(1), USER_A, uint64(1e18 + 1));
    }

    function test_requestDeposit_revertsOnDisabledTranche() public {
        address unregistered = makeAddr("UNREGISTERED_TRANCHE");
        vm.expectRevert(IRoycoDayEntryPoint.TRANCHE_NOT_ENABLED.selector);
        vm.prank(USER_A);
        entryPoint.requestDeposit(unregistered, toTrancheUnits(1), USER_A, 0);
    }

    // ---------------------------------------------------------------------
    // executeDeposit: timing
    // ---------------------------------------------------------------------

    function test_executeDeposit_revertsBeforeDelayElapses() public {
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(juniorTranche), _depositAmount(address(juniorTranche)));
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.INVALID_REQUEST.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));
    }

    function test_executeDeposit_succeedsExactlyAtExecutableTimestamp() public {
        (uint256 nonce, uint32 executableAt) = _requestDepositDefault(USER_A, address(juniorTranche), _depositAmount(address(juniorTranche)));
        vm.warp(executableAt);
        priceFeed.setUpdatedAt(block.timestamp);
        uint256 shares = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(shares, 0, "execution at the exact boundary must succeed");
    }

    function test_executeDeposit_revertsForNonExistentRequest() public {
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.INVALID_REQUEST.selector, 999));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, 999, toTrancheUnits(1));
    }

    function test_executeDeposit_revertsOnZeroAmount() public {
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(juniorTranche), _depositAmount(address(juniorTranche)));
        _warpPastDepositDelay();
        vm.expectRevert(IRoycoDayEntryPoint.MUST_EXECUTE_NON_ZERO_AMOUNT.selector);
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(0));
    }

    // ---------------------------------------------------------------------
    // executeDeposit: self execution
    // ---------------------------------------------------------------------

    function test_executeDeposit_self_mintsSharesToReceiver_allTranches() public {
        address[3] memory tranches = _tranches();
        for (uint256 i = 0; i < 3; ++i) {
            address tranche = tranches[i];
            uint256 amount = _depositAmount(tranche);
            (uint256 nonce,) = _requestDeposit(USER_A, tranche, amount, USER_B, 0);
            _warpPastDepositDelay();

            uint256 receiverSharesBefore = IERC20Like(tranche).balanceOf(USER_B);
            uint256 shares = _executeDepositMax(USER_A, USER_A, nonce);

            assertGt(shares, 0, "shares must be minted");
            assertEq(IERC20Like(tranche).balanceOf(USER_B) - receiverSharesBefore, shares, "shares must land on the request receiver");
            assertEq(toUint256(entryPoint.getDepositRequest(USER_A, nonce).assets), 0, "fully executed request must be deleted");
        }
    }

    function test_executeDeposit_partialThenFull() public {
        uint256 amount = _depositAmount(address(juniorTranche));
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(juniorTranche), amount);
        _warpPastDepositDelay();

        uint256 firstShares = _executeDeposit(USER_A, USER_A, nonce, amount / 4);
        IRoycoDayEntryPoint.DepositRequest memory request = entryPoint.getDepositRequest(USER_A, nonce);
        assertEq(request.assets, toTrancheUnits(amount - amount / 4), "remaining assets must be tracked after partial execution");

        uint256 secondShares = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(firstShares, 0, "first slice must mint shares");
        assertGt(secondShares, 0, "second slice must mint shares");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, nonce).assets), 0, "request must be deleted after full execution");

        // Executing again must revert: the request no longer exists
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.INVALID_REQUEST.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(1));
    }

    function test_executeDeposit_partial_scalesNavSnapshotProRata() public {
        uint256 amount = _depositAmount(address(juniorTranche));
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(juniorTranche), amount);
        uint256 navBefore = toUint256(entryPoint.getDepositRequest(USER_A, nonce).baseRequest.navAtRequestTime);
        _warpPastDepositDelay();

        _executeDeposit(USER_A, USER_A, nonce, amount / 2);
        uint256 navAfter = toUint256(entryPoint.getDepositRequest(USER_A, nonce).baseRequest.navAtRequestTime);
        // Exact floor: the remaining slice floors so the executed slice keeps the rounding, keeping forfeiture conservative
        assertEq(navAfter, Math.mulDiv(navBefore, amount - (amount / 2), amount), "nav snapshot must floor-scale by the remaining assets");
    }

    function test_executeDeposit_maxSentinel_capacityBound_partialFillsAndQueuesRemainder() public {
        // Request more than the market's deposit capacity: the sentinel must fill exactly the capacity and queue the rest
        uint256 capacity = toUint256(seniorTranche.maxDeposit(address(entryPoint)));
        assertGt(capacity, 0, "arrange: the market must have senior deposit capacity");
        uint256 amount = capacity * 2;
        (uint256 nonce,) = _requestDeposit(USER_A, address(seniorTranche), amount, USER_A, 0);
        uint256 navBefore = toUint256(entryPoint.getDepositRequest(USER_A, nonce).baseRequest.navAtRequestTime);
        _warpPastDepositDelay();

        uint256 minted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(minted, 0, "the capacity-bound fill must mint shares");
        uint256 executed = amount - toUint256(entryPoint.getDepositRequest(USER_A, nonce).assets);
        assertGt(executed, 0, "the sentinel must fill the market's capacity");
        assertLt(executed, amount, "the capacity, not the request, must bind the fill");
        assertEq(
            toUint256(entryPoint.getDepositRequest(USER_A, nonce).baseRequest.navAtRequestTime),
            Math.mulDiv(navBefore, amount - executed, amount),
            "the queued remainder's snapshot must floor-scale by the unfilled assets"
        );
    }

    function test_executeDeposit_overExecutionReverts() public {
        uint256 amount = _depositAmount(address(juniorTranche));
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(juniorTranche), amount);
        _warpPastDepositDelay();
        // Specifically the escrow-remainder underflow: over-execution must never be admitted by an earlier gate
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(amount + 1));
    }

    function test_executeDeposit_revertsWhenTrancheDisabledAfterRequest() public {
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(juniorTranche), _depositAmount(address(juniorTranche)));
        _warpPastDepositDelay();

        // Disable the tranche
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        configs[1].enabled = false;
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.modifyTrancheConfigs(tranches, configs);

        vm.expectRevert(IRoycoDayEntryPoint.TRANCHE_NOT_ENABLED.selector);
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        // The escrow remains cancellable
        _cancelDeposit(USER_A, nonce, USER_A);
    }

    // ---------------------------------------------------------------------
    // executeDeposit: third-party execution
    // ---------------------------------------------------------------------

    function test_executeDeposit_thirdParty_paysBonusInAssets() public {
        uint256 amount = _depositAmount(address(juniorTranche));
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(juniorTranche), amount);
        _warpPastDepositDelay();

        uint256 executorAssetsBefore = stJtVault.balanceOf(EXECUTOR);
        uint256 shares = _executeDepositMax(EXECUTOR, USER_A, nonce);

        uint256 expectedBonus = (amount * DEFAULT_EXECUTOR_BONUS) / 1e18;
        assertEq(stJtVault.balanceOf(EXECUTOR) - executorAssetsBefore, expectedBonus, "executor must receive the flooring bonus in assets");
        assertGt(shares, 0, "the remainder must be deposited for the receiver");
    }

    function test_executeDeposit_thirdParty_zeroBonusPathMintsDirectly() public {
        uint256 amount = _depositAmount(address(juniorTranche));
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);
        _warpPastDepositDelay();

        uint256 executorAssetsBefore = stJtVault.balanceOf(EXECUTOR);
        uint256 shares = _executeDepositMax(EXECUTOR, USER_A, nonce);
        assertEq(stJtVault.balanceOf(EXECUTOR), executorAssetsBefore, "a zero-bonus execution pays the executor nothing");
        assertGt(shares, 0, "the full amount must be deposited for the receiver");
    }

    function test_executeDeposit_thirdParty_tinyAmountBonusRoundsToZero() public {
        // 50 wei at a 1% bonus floors to 0 bonus assets
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 50, USER_A, DEFAULT_EXECUTOR_BONUS);
        _warpPastDepositDelay();
        uint256 executorAssetsBefore = stJtVault.balanceOf(EXECUTOR);
        _executeDepositMax(EXECUTOR, USER_A, nonce);
        assertEq(stJtVault.balanceOf(EXECUTOR), executorAssetsBefore, "a dust bonus must floor to zero");
    }

    // ---------------------------------------------------------------------
    // cancelDepositRequest
    // ---------------------------------------------------------------------

    function test_cancelDepositRequest_returnsEscrowToReceiver() public {
        uint256 amount = _depositAmount(address(seniorTranche));
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(seniorTranche), amount);

        uint256 receiverAssetsBefore = stJtVault.balanceOf(USER_B);
        _cancelDeposit(USER_A, nonce, USER_B);
        assertEq(stJtVault.balanceOf(USER_B) - receiverAssetsBefore, amount, "cancelled escrow must land on the specified receiver");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, nonce).assets), 0, "cancelled request must be deleted");
    }

    function test_cancelDepositRequest_afterPartialExecution_returnsRemainder() public {
        uint256 amount = _depositAmount(address(juniorTranche));
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(juniorTranche), amount);
        _warpPastDepositDelay();
        _executeDeposit(USER_A, USER_A, nonce, amount / 4);

        uint256 balanceBefore = stJtVault.balanceOf(USER_A);
        _cancelDeposit(USER_A, nonce, USER_A);
        assertEq(stJtVault.balanceOf(USER_A) - balanceBefore, amount - amount / 4, "the unexecuted remainder must be returned");
    }

    function test_cancelDepositRequest_revertsForNonOwnerNonce() public {
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(seniorTranche), _depositAmount(address(seniorTranche)));
        // USER_B does not own this nonce, their request slot is empty
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.INVALID_REQUEST.selector, nonce));
        vm.prank(USER_B);
        entryPoint.cancelDepositRequest(nonce, USER_B);
    }

    function test_cancelDepositRequest_revertsOnNullReceiver() public {
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(seniorTranche), _depositAmount(address(seniorTranche)));
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        vm.prank(USER_A);
        entryPoint.cancelDepositRequest(nonce, address(0));
    }

    function test_cancelDepositRequest_executeAfterCancelReverts() public {
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(seniorTranche), _depositAmount(address(seniorTranche)));
        _cancelDeposit(USER_A, nonce, USER_A);
        _warpPastDepositDelay();
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.INVALID_REQUEST.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));
    }

    // ---------------------------------------------------------------------
    // Batch semantics
    // ---------------------------------------------------------------------

    function test_executeDeposits_acrossUsersAndTranches() public {
        uint256 jtAmount = _depositAmount(address(juniorTranche));
        uint256 ltAmount = _depositAmount(address(liquidityTranche));
        (uint256 nonceA,) = _requestDeposit(USER_A, address(juniorTranche), jtAmount, USER_A, 0);
        (uint256 nonceB,) = _requestDeposit(USER_B, address(liquidityTranche), ltAmount, USER_B, 0);
        _warpPastDepositDelay();

        address[] memory users = new address[](2);
        users[0] = USER_A;
        users[1] = USER_B;
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = nonceA;
        nonces[1] = nonceB;
        TRANCHE_UNIT[] memory amounts = new TRANCHE_UNIT[](2);
        amounts[0] = toTrancheUnits(type(uint256).max);
        amounts[1] = toTrancheUnits(type(uint256).max);

        vm.prank(USER_A);
        uint256[] memory minted = entryPoint.executeDeposits(users, nonces, amounts);
        assertGt(minted[0], 0, "the JT deposit in the batch must mint shares");
        assertGt(minted[1], 0, "the LT deposit in the batch must mint shares");
    }

    function test_executeDeposits_revertsOnLengthMismatch() public {
        address[] memory users = new address[](2);
        uint256[] memory nonces = new uint256[](1);
        vm.expectRevert(IRoycoDayEntryPoint.ARRAY_LENGTH_MISMATCH.selector);
        vm.prank(USER_A);
        entryPoint.executeDeposits(users, nonces, new TRANCHE_UNIT[](2));
    }

    function test_executeDeposits_emptyArraysAreANoOp() public {
        vm.prank(USER_A);
        uint256[] memory minted = entryPoint.executeDeposits(new address[](0), new uint256[](0), new TRANCHE_UNIT[](0));
        assertEq(minted.length, 0, "an empty batch must no-op");
    }

    function test_cancelDepositRequests_batchCancelsAll() public {
        uint256 amount = _depositAmount(address(seniorTranche));
        (uint256 nonce1,) = _requestDepositDefault(USER_A, address(seniorTranche), amount);
        (uint256 nonce2,) = _requestDepositDefault(USER_A, address(juniorTranche), amount);

        uint256[] memory nonces = new uint256[](2);
        nonces[0] = nonce1;
        nonces[1] = nonce2;
        uint256 balanceBefore = stJtVault.balanceOf(USER_A);
        vm.prank(USER_A);
        entryPoint.cancelDepositRequests(nonces, USER_A);
        assertEq(stJtVault.balanceOf(USER_A) - balanceBefore, 2 * amount, "both escrows must be returned");
    }

    function test_cancelDepositRequests_delayedRoleBatchExecutesDirectlyThroughSingleRestrictedGate() public {
        // Rebind the batch selector to a dedicated role and grant it to USER_A with an execution delay
        uint64 delayedCancelRole = 424_242;
        accessManager.setTargetFunctionRole(address(entryPoint), _sels(IRoycoDayEntryPoint.cancelDepositRequests.selector), delayedCancelRole);
        accessManager.grantRole(delayedCancelRole, USER_A, 1 days);

        // Two live requests so the batch loops the internal cancel more than once
        uint256 amount = _depositAmount(address(seniorTranche));
        (uint256 nonce1,) = _requestDepositDefault(USER_A, address(seniorTranche), amount);
        (uint256 nonce2,) = _requestDepositDefault(USER_A, address(juniorTranche), amount);
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = nonce1;
        nonces[1] = nonce2;

        bytes memory callData = abi.encodeCall(entryPoint.cancelDepositRequests, (nonces, USER_A));

        // Unscheduled direct call: the single gate consumes a schedule that does not exist and reverts typed, so the delay genuinely bites
        bytes32 operationId = accessManager.hashOperation(USER_A, address(entryPoint), callData);
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, operationId));
        entryPoint.cancelDepositRequests(nonces, USER_A);

        // Schedule, wait out the delay, then the DIRECT batch call must land: restricted runs once for the whole
        // frame, so the second cancellation in the loop cannot re-consume the schedule and revert mid-batch
        vm.prank(USER_A);
        accessManager.schedule(address(entryPoint), callData, uint48(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);
        uint256 balanceBefore = stJtVault.balanceOf(USER_A);
        vm.prank(USER_A);
        entryPoint.cancelDepositRequests(nonces, USER_A);
        assertEq(stJtVault.balanceOf(USER_A) - balanceBefore, 2 * amount, "both escrows must be returned by the delayed batch cancel");
    }

    // ---------------------------------------------------------------------
    // Pause
    // ---------------------------------------------------------------------

    function test_entryPointPaused_blocksDepositLifecycle() public {
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(juniorTranche), _depositAmount(address(juniorTranche)));
        _warpPastDepositDelay();

        vm.prank(PAUSER);
        IRoycoAuth(address(entryPoint)).pause();

        vm.startPrank(USER_A);
        vm.expectRevert();
        entryPoint.requestDeposit(address(juniorTranche), toTrancheUnits(1), USER_A, 0);
        vm.expectRevert();
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));
        vm.expectRevert();
        entryPoint.cancelDepositRequest(nonce, USER_A);
        vm.stopPrank();

        // Unpause remediates
        vm.prank(UNPAUSER);
        IRoycoAuth(address(entryPoint)).unpause();
        uint256 shares = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(shares, 0, "execution must succeed after unpausing");
    }

    function test_trancheOrKernelPaused_blocksExecutionButNotEscrow() public {
        uint256 amount = _depositAmount(address(juniorTranche));
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(juniorTranche), amount);
        _warpPastDepositDelay();

        // Pausing the kernel blocks the tranche's deposit path but the entry point's escrow surface stays live
        vm.prank(PAUSER);
        IRoycoAuth(address(kernel)).pause();

        // Under the MAX sentinel a paused kernel reads as maxDeposit == 0, so the execution gracefully skips
        uint256 minted = _executeDepositMax(USER_A, USER_A, nonce);
        assertEq(minted, 0, "a paused kernel must gracefully skip a MAX-sentinel execution");
        assertEq(entryPoint.getDepositRequest(USER_A, nonce).assets, toTrancheUnits(amount), "the skipped request must remain queued");

        // An explicit amount reaches the paused tranche deposit path and reverts
        vm.expectRevert();
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(amount));

        // Cancellation still works while the kernel is paused
        _cancelDeposit(USER_A, nonce, USER_A);
    }
}
