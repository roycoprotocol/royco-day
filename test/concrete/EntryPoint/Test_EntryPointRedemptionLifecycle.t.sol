// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase, IERC20Like } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointRedemptionLifecycle
 * @notice The redemption half of the entry point's request/execute/cancel lifecycle across all three tranches:
 *         share escrow, delay enforcement, self vs third-party execution with claim-splitting bonuses, partial
 *         execution, cancellation, and batch semantics
 */
contract Test_EntryPointRedemptionLifecycle is EntryPointTestBase {
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
    }

    /// @dev Acquires shares and registers a redemption request for them in one step
    function _acquireAndRequest(
        address _user,
        address _tranche,
        uint256 _assets,
        address _receiver,
        uint64 _bonus
    )
        internal
        returns (uint256 shares, uint256 nonce)
    {
        shares = _acquireTrancheShares(_user, _tranche, _assets);
        (nonce,) = _requestRedemption(_user, _tranche, shares, _receiver, _bonus);
    }

    // ---------------------------------------------------------------------
    // requestRedemption
    // ---------------------------------------------------------------------

    function test_requestRedemption_escrowsSharesAndRegistersRequest_allTranches() public {
        address[3] memory tranches = [address(seniorTranche), address(juniorTranche), address(liquidityProviderTranche)];
        for (uint256 i = 0; i < 3; ++i) {
            address tranche = tranches[i];
            uint256 assets = tranche == address(liquidityProviderTranche) ? 10e18 : 10 * stUnit;
            (uint256 shares, uint256 nonce) = _acquireAndRequest(USER_A, tranche, assets, USER_A, DEFAULT_EXECUTOR_BONUS);

            assertEq(IERC20Like(tranche).balanceOf(address(entryPoint)), shares, "shares must be escrowed in the entry point");
            assertEq(IERC20Like(tranche).balanceOf(USER_A), 0, "the user's shares must have moved into escrow");
            IRoycoDayEntryPoint.RedemptionRequest memory request = entryPoint.getRedemptionRequest(USER_A, nonce);
            assertEq(request.shares, shares, "request shares");
            assertEq(request.baseRequest.tranche, tranche, "request tranche");
            assertGt(toUint256(request.baseRequest.navAtRequestTime), 0, "the nav snapshot must be taken on every request");

            // Clean up the escrow so the next tranche iteration starts from zero balances
            _cancelRedemption(USER_A, nonce, USER_A);
        }
    }

    function test_requestRedemption_revertsOnZeroShares() public {
        vm.expectRevert(IRoycoDayEntryPoint.MUST_EXECUTE_NON_ZERO_AMOUNT.selector);
        vm.prank(USER_A);
        entryPoint.requestRedemption(address(seniorTranche), 0, USER_A, 0);
    }

    function test_requestRedemption_revertsOnDisabledTranche() public {
        vm.expectRevert(IRoycoDayEntryPoint.TRANCHE_NOT_ENABLED.selector);
        vm.prank(USER_A);
        entryPoint.requestRedemption(makeAddr("UNKNOWN"), 1, USER_A, 0);
    }

    function test_requestRedemption_revertsOnNullTrancheOrReceiver() public {
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        vm.prank(USER_A);
        entryPoint.requestRedemption(address(0), 1, USER_A, 0);

        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        vm.prank(USER_A);
        entryPoint.requestRedemption(address(seniorTranche), 1, address(0), 0);
    }

    function test_requestRedemption_revertsOnInvalidBonus() public {
        // The bonus must be strictly less than 100%: at exactly WAD the user's claim remainder would be zero
        vm.expectRevert(IRoycoDayEntryPoint.INVALID_EXECUTOR_BONUS.selector);
        vm.prank(USER_A);
        entryPoint.requestRedemption(address(seniorTranche), 1, USER_A, uint64(1e18));

        vm.expectRevert(IRoycoDayEntryPoint.INVALID_EXECUTOR_BONUS.selector);
        vm.prank(USER_A);
        entryPoint.requestRedemption(address(seniorTranche), 1, USER_A, uint64(1e18 + 1));
    }

    // ---------------------------------------------------------------------
    // executeRedemption: self execution
    // ---------------------------------------------------------------------

    function test_executeRedemption_self_deliversClaimsToReceiver() public {
        (, uint256 nonce) = _acquireAndRequest(USER_A, address(juniorTranche), 10 * stUnit, USER_B, DEFAULT_EXECUTOR_BONUS);
        _warpPastRedemptionDelay();

        uint256 receiverAssetsBefore = stJtVault.balanceOf(USER_B);
        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);

        assertGt(toUint256(claims.nav), 0, "the redemption must produce claims");
        uint256 assetsDelivered = toUint256(claims.collateralAssets);
        assertEq(stJtVault.balanceOf(USER_B) - receiverAssetsBefore, assetsDelivered, "the claims must be delivered directly to the receiver");
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonce).shares, 0, "fully executed request must be deleted");
    }

    function test_executeRedemption_revertsBeforeDelayElapses() public {
        (, uint256 nonce) = _acquireAndRequest(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.INVALID_REQUEST.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);
    }

    function test_executeRedemption_revertsOnZeroShares() public {
        (, uint256 nonce) = _acquireAndRequest(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        _warpPastRedemptionDelay();
        vm.expectRevert(IRoycoDayEntryPoint.MUST_EXECUTE_NON_ZERO_AMOUNT.selector);
        vm.prank(USER_A);
        entryPoint.executeRedemption(USER_A, nonce, 0);
    }

    function test_executeRedemption_revertsWhenTrancheDisabledAfterRequest() public {
        (uint256 shares, uint256 nonce) = _acquireAndRequest(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        _warpPastRedemptionDelay();

        // Disable the tranche
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        configs[1].enabled = false;
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.modifyTrancheConfigs(tranches, configs);

        vm.expectRevert(IRoycoDayEntryPoint.TRANCHE_NOT_ENABLED.selector);
        vm.prank(USER_A);
        entryPoint.executeRedemption(USER_A, nonce, shares);

        // The escrowed shares remain cancellable
        _cancelRedemption(USER_A, nonce, USER_A);
    }

    function test_executeRedemption_partialThenFull_scalesNavProRata() public {
        (uint256 shares, uint256 nonce) = _acquireAndRequest(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        uint256 navBefore = toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).baseRequest.navAtRequestTime);
        _warpPastRedemptionDelay();

        _executeRedemption(USER_A, USER_A, nonce, shares / 2);
        IRoycoDayEntryPoint.RedemptionRequest memory request = entryPoint.getRedemptionRequest(USER_A, nonce);
        assertEq(request.shares, shares - shares / 2, "remaining shares must be tracked after partial execution");
        assertApproxEqAbs(toUint256(request.baseRequest.navAtRequestTime), navBefore / 2, 1, "nav snapshot must scale pro-rata with the remaining shares");

        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);
        assertGt(toUint256(claims.nav), 0, "the second slice must produce claims");
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonce).shares, 0, "request must be deleted after full execution");
    }

    // ---------------------------------------------------------------------
    // executeRedemption: third-party execution
    // ---------------------------------------------------------------------

    function test_executeRedemption_thirdParty_splitsClaimsBetweenExecutorAndReceiver() public {
        (, uint256 nonce) = _acquireAndRequest(USER_A, address(juniorTranche), 10 * stUnit, USER_B, DEFAULT_EXECUTOR_BONUS);
        _warpPastRedemptionDelay();

        uint256 executorBefore = stJtVault.balanceOf(EXECUTOR);
        uint256 receiverBefore = stJtVault.balanceOf(USER_B);
        AssetClaims memory userClaims = _executeRedemptionMax(EXECUTOR, USER_A, nonce);

        uint256 executorDelta = stJtVault.balanceOf(EXECUTOR) - executorBefore;
        uint256 receiverDelta = stJtVault.balanceOf(USER_B) - receiverBefore;
        assertGt(executorDelta, 0, "the executor must receive its bonus slice of the claims");
        assertEq(receiverDelta, toUint256(userClaims.collateralAssets), "the receiver must get the post-bonus user claims");
        // Bonus conservation: the executor's slice is ~1% of the total delivered claims (floor rounding per leg).
        // The bonus is a _scaleAssetClaims slice priced against the virtual-shares effective denominator (WAD + 1e6),
        // so the derivation divides by (1e18 + 1e6), not WAD.
        uint256 total = executorDelta + receiverDelta;
        assertApproxEqAbs(executorDelta, (total * DEFAULT_EXECUTOR_BONUS) / (1e18 + 1e6), 2, "the executor slice must equal the flooring bonus fraction");
        // Nothing may be left stranded in the entry point
        assertEq(stJtVault.balanceOf(address(entryPoint)), 0, "no claim assets may remain in the entry point after the split");
    }

    function test_executeRedemption_thirdParty_optOutSentinelReverts() public {
        (, uint256 nonce) = _acquireAndRequest(USER_A, address(juniorTranche), 10 * stUnit, USER_A, type(uint64).max);
        _warpPastRedemptionDelay();
        vm.expectRevert(IRoycoDayEntryPoint.THIRD_PARTY_EXECUTION_DISABLED.selector);
        vm.prank(EXECUTOR);
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // cancelRedemptionRequest
    // ---------------------------------------------------------------------

    function test_cancelRedemptionRequest_returnsEscrowedShares() public {
        (uint256 shares, uint256 nonce) = _acquireAndRequest(USER_A, address(seniorTranche), 10 * stUnit, USER_A, 0);
        _cancelRedemption(USER_A, nonce, USER_B);
        assertEq(seniorTranche.balanceOf(USER_B), shares, "cancelled escrowed shares must land on the specified receiver");
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonce).shares, 0, "cancelled request must be deleted");
    }

    function test_cancelRedemptionRequest_afterPartial_returnsRemainder() public {
        (uint256 shares, uint256 nonce) = _acquireAndRequest(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        _warpPastRedemptionDelay();
        _executeRedemption(USER_A, USER_A, nonce, shares / 4);

        _cancelRedemption(USER_A, nonce, USER_A);
        assertEq(juniorTranche.balanceOf(USER_A), shares - shares / 4, "the unexecuted share remainder must be returned");
    }

    function test_cancelRedemptionRequest_revertsForNonOwnerNonce() public {
        (, uint256 nonce) = _acquireAndRequest(USER_A, address(seniorTranche), 10 * stUnit, USER_A, 0);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.INVALID_REQUEST.selector, nonce));
        vm.prank(USER_B);
        entryPoint.cancelRedemptionRequest(nonce, USER_B);
    }

    // ---------------------------------------------------------------------
    // Batch semantics
    // ---------------------------------------------------------------------

    function test_cancelRedemptionRequests_batchCancelsAll() public {
        (uint256 sharesSt, uint256 nonceSt) = _acquireAndRequest(USER_A, address(seniorTranche), 10 * stUnit, USER_A, 0);
        (uint256 sharesJt, uint256 nonceJt) = _acquireAndRequest(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        uint256[] memory nonces = new uint256[](2);
        nonces[0] = nonceSt;
        nonces[1] = nonceJt;
        vm.prank(USER_A);
        entryPoint.cancelRedemptionRequests(nonces, USER_A);
        assertEq(seniorTranche.balanceOf(USER_A), sharesSt, "the senior escrow must be returned");
        assertEq(juniorTranche.balanceOf(USER_A), sharesJt, "the junior escrow must be returned");
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonceSt).shares, 0, "the senior request must be deleted");
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonceJt).shares, 0, "the junior request must be deleted");
    }

    function test_cancelRedemptionRequests_delayedRoleBatchExecutesDirectlyThroughSingleRestrictedGate() public {
        // Rebind the batch selector to a dedicated role and grant it to USER_A with an execution delay
        uint64 delayedCancelRole = 424_242;
        accessManager.setTargetFunctionRole(address(entryPoint), _sels(IRoycoDayEntryPoint.cancelRedemptionRequests.selector), delayedCancelRole);
        accessManager.grantRole(delayedCancelRole, USER_A, 1 days);

        // Two live requests so the batch loops the internal cancel more than once
        (uint256 sharesSt, uint256 nonceSt) = _acquireAndRequest(USER_A, address(seniorTranche), 10 * stUnit, USER_A, 0);
        (uint256 sharesJt, uint256 nonceJt) = _acquireAndRequest(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = nonceSt;
        nonces[1] = nonceJt;

        bytes memory callData = abi.encodeCall(entryPoint.cancelRedemptionRequests, (nonces, USER_A));

        // Unscheduled direct call: the single gate consumes a schedule that does not exist and reverts typed, so the delay genuinely bites
        bytes32 operationId = accessManager.hashOperation(USER_A, address(entryPoint), callData);
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, operationId));
        entryPoint.cancelRedemptionRequests(nonces, USER_A);

        // Schedule, wait out the delay, then the DIRECT batch call must land: restricted runs once for the whole
        // frame, so the second cancellation in the loop cannot re-consume the schedule and revert mid-batch
        vm.prank(USER_A);
        accessManager.schedule(address(entryPoint), callData, uint48(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);
        vm.prank(USER_A);
        entryPoint.cancelRedemptionRequests(nonces, USER_A);
        assertEq(seniorTranche.balanceOf(USER_A), sharesSt, "the senior escrow must be returned by the delayed batch cancel");
        assertEq(juniorTranche.balanceOf(USER_A), sharesJt, "the junior escrow must be returned by the delayed batch cancel");
    }

    function test_executeRedemptions_acrossUsers() public {
        (, uint256 nonceA) = _acquireAndRequest(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        (, uint256 nonceB) = _acquireAndRequest(USER_B, address(juniorTranche), 10 * stUnit, USER_B, 0);
        _warpPastRedemptionDelay();

        address[] memory users = new address[](2);
        users[0] = USER_A;
        users[1] = USER_B;
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = nonceA;
        nonces[1] = nonceB;
        uint256[] memory sharesToRedeem = new uint256[](2);
        sharesToRedeem[0] = type(uint256).max;
        sharesToRedeem[1] = type(uint256).max;

        vm.prank(USER_A);
        (AssetClaims[] memory claims,) = entryPoint.executeRedemptions(users, nonces, sharesToRedeem);
        assertGt(toUint256(claims[0].nav), 0, "USER_A's redemption must produce claims");
        assertGt(toUint256(claims[1].nav), 0, "USER_B's redemption must produce claims");
    }

    function test_executeRedemptions_revertsOnLengthMismatch() public {
        vm.expectRevert(IRoycoDayEntryPoint.ARRAY_LENGTH_MISMATCH.selector);
        vm.prank(USER_A);
        entryPoint.executeRedemptions(new address[](2), new uint256[](1), new uint256[](2));
    }

    // ---------------------------------------------------------------------
    // Pause
    // ---------------------------------------------------------------------

    function test_entryPointPaused_blocksRedemptionLifecycle() public {
        (, uint256 nonce) = _acquireAndRequest(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        _warpPastRedemptionDelay();

        vm.prank(PAUSER);
        IRoycoAuth(address(entryPoint)).pause();

        vm.startPrank(USER_A);
        vm.expectRevert();
        entryPoint.requestRedemption(address(juniorTranche), 1, USER_A, 0);
        vm.expectRevert();
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);
        vm.expectRevert();
        entryPoint.cancelRedemptionRequest(nonce, USER_A);
        vm.stopPrank();

        vm.prank(UNPAUSER);
        IRoycoAuth(address(entryPoint)).unpause();
        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);
        assertGt(toUint256(claims.nav), 0, "execution must succeed after unpausing");
    }
}
