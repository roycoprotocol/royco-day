// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoycoBlacklist } from "../../../src/auth/RoycoBlacklist.sol";
import { IRoycoBlacklist } from "../../../src/interfaces/IRoycoBlacklist.sol";
import { MAX_TRANCHE_UNITS } from "../../../src/libraries/Constants.sol";
import { TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase, IERC20Like } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointBlacklistScreening
 * @notice The entry point's blacklist integration end to end: every flow whose value settles outside the kernel's
 *         screened paths (asset escrow movements, executor bonuses, third party remittances) screens its parties
 *         through the tranche's kernel, and every flow whose value routes through the kernel's own screens (share
 *         escrow transfers, mints, redemption receiver checks) is pinned as already covered without a second screen
 * @dev Screening is a compliance hard-stop: a hole lets a flagged account queue, execute, or exfiltrate escrowed
 *      value, so both directions of every flow are pinned (flagged reverts, unblacklisted control lands). The
 *      blacklist is wired per test so the null-blacklist no-op and the live-read (wired after queueing) properties
 *      are pinned against the same requests
 */
contract Test_EntryPointBlacklistScreening is EntryPointTestBase {
    /// @dev The production blacklist behind a proxy, administered by this test through the market's access manager
    RoycoBlacklist internal roycoBlacklist;

    /// @dev A role-holding receiver distinct from the requesting users, so receiver screening is pinned independently
    address internal RECEIVER;

    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
        roycoBlacklist = RoycoBlacklist(
            address(
                new ERC1967Proxy(
                    address(new RoycoBlacklist()), abi.encodeCall(RoycoBlacklist.initialize, (address(accessManager), address(0), new address[](0)))
                )
            )
        );
        RECEIVER = _generateEntryPointUser("RECEIVER");
    }

    /// @dev Wires the blacklist into the market's kernel, the entry point resolves it live through the kernel on every screen
    function _wireBlacklist() internal {
        vm.prank(MARKET_OPS_ADMIN);
        kernel.setRoycoBlacklist(address(roycoBlacklist));
    }

    /// @dev Wraps a single account in the calldata array shape the mutation functions take
    function _one(address _account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = _account;
    }

    /// @dev Flags an account on the market's blacklist
    function _flag(address _account) internal {
        roycoBlacklist.blacklistAccounts(_one(_account));
    }

    /// @dev The ACCOUNT_BLACKLISTED revert payload for the specified account
    function _blacklistedError(address _account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, _account);
    }

    /// @dev Funds and approves a deposit's assets without requesting, so revert-path tests can call requestDeposit raw
    function _fundAndApproveDeposit(address _user, uint256 _assets) internal {
        _fundTrancheAssets(_user, address(seniorTranche), _assets);
        address asset = seniorTranche.asset();
        vm.prank(_user);
        IERC20Like(asset).approve(address(entryPoint), _assets);
    }

    // ---------------------------------------------------------------------
    // The kernel's screening surface
    // ---------------------------------------------------------------------

    /// @notice With no blacklist configured the kernel screen is a no-op, so every entry point flow passes for any account
    function test_kernelEnforceNotBlacklisted_noopWithoutBlacklist() public {
        kernel.enforceNotBlacklisted(_one(USER_A));
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(seniorTranche), 10 * stUnit);
        _warpPastDepositDelay();
        assertGt(_executeDepositMax(EXECUTOR, USER_A, nonce), 0, "an unscreened market must execute freely");
    }

    /// @notice The kernel screen reverts on a flagged account, skips the null sentinel, and clears on unblacklisting
    function test_kernelEnforceNotBlacklisted_revertsOnFlaggedSkipsNullAndClears() public {
        _wireBlacklist();
        _flag(USER_B);

        address[] memory accounts = new address[](3);
        accounts[0] = USER_A;
        accounts[1] = address(0);
        accounts[2] = USER_B;
        vm.expectRevert(_blacklistedError(USER_B));
        kernel.enforceNotBlacklisted(accounts);

        // The null sentinel is skipped and clean accounts pass
        accounts[2] = USER_A;
        kernel.enforceNotBlacklisted(accounts);

        // Unblacklisting clears the screen
        roycoBlacklist.unblacklistAccounts(_one(USER_B));
        kernel.enforceNotBlacklisted(_one(USER_B));
    }

    // ---------------------------------------------------------------------
    // requestDeposit
    // ---------------------------------------------------------------------

    /// @notice A flagged requester cannot queue a deposit, the asset escrow settles outside the kernel's screened flows
    function test_requestDeposit_revertsOnFlaggedRequester() public {
        _wireBlacklist();
        _flag(USER_A);
        _fundAndApproveDeposit(USER_A, 10 * stUnit);

        vm.expectRevert(_blacklistedError(USER_A));
        vm.prank(USER_A);
        entryPoint.requestDeposit(address(seniorTranche), toTrancheUnits(10 * stUnit), USER_A, 0);
    }

    /// @notice A flagged receiver cannot be designated on a deposit request
    function test_requestDeposit_revertsOnFlaggedReceiver() public {
        _wireBlacklist();
        _flag(RECEIVER);
        _fundAndApproveDeposit(USER_A, 10 * stUnit);

        vm.expectRevert(_blacklistedError(RECEIVER));
        vm.prank(USER_A);
        entryPoint.requestDeposit(address(seniorTranche), toTrancheUnits(10 * stUnit), RECEIVER, 0);

        // Unblacklisting restores the request path
        roycoBlacklist.unblacklistAccounts(_one(RECEIVER));
        vm.prank(USER_A);
        entryPoint.requestDeposit(address(seniorTranche), toTrancheUnits(10 * stUnit), RECEIVER, 0);
    }

    // ---------------------------------------------------------------------
    // requestRedemption
    // ---------------------------------------------------------------------

    /// @notice A flagged receiver cannot be designated on a redemption request
    function test_requestRedemption_revertsOnFlaggedReceiver() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        _wireBlacklist();
        _flag(RECEIVER);

        vm.startPrank(USER_A);
        IERC20Like(address(seniorTranche)).approve(address(entryPoint), shares);
        vm.expectRevert(_blacklistedError(RECEIVER));
        entryPoint.requestRedemption(address(seniorTranche), shares, RECEIVER, 0);
        vm.stopPrank();
    }

    /// @notice A flagged requester is stopped by the share escrow transfer's kernel screen, no entry point screen needed
    function test_requestRedemption_flaggedRequesterStoppedByEscrowTransferScreen() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        _wireBlacklist();
        _flag(USER_A);

        vm.startPrank(USER_A);
        IERC20Like(address(seniorTranche)).approve(address(entryPoint), shares);
        vm.expectRevert(_blacklistedError(USER_A));
        entryPoint.requestRedemption(address(seniorTranche), shares, RECEIVER, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // executeDeposit
    // ---------------------------------------------------------------------

    /// @notice A flagged third party executor cannot execute, the bonus assets settle outside the kernel's screened flows
    function test_executeDeposit_revertsOnFlaggedThirdPartyExecutor() public {
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(seniorTranche), 10 * stUnit);
        _warpPastDepositDelay();
        _wireBlacklist();
        _flag(EXECUTOR);

        vm.expectRevert(_blacklistedError(EXECUTOR));
        vm.prank(EXECUTOR);
        entryPoint.executeDeposit(USER_A, nonce, MAX_TRANCHE_UNITS);
    }

    /// @notice An explicit-amount execution to a receiver flagged after queueing is stopped by the tranche deposit's kernel mint screen
    function test_executeDeposit_flaggedReceiverStoppedByKernelMintScreen() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(seniorTranche), 10 * stUnit, RECEIVER, DEFAULT_EXECUTOR_BONUS);
        _warpPastDepositDelay();
        _wireBlacklist();
        _flag(RECEIVER);

        vm.expectRevert(_blacklistedError(RECEIVER));
        vm.prank(EXECUTOR);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(10 * stUnit));
    }

    /// @notice A max-sentinel execution to a flagged receiver settles as a graceful no-op, the blacklist-aware maxDeposit reads zero so keeper batches are never griefed
    function test_executeDeposit_maxSentinelNoopsOnFlaggedReceiver() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(seniorTranche), 10 * stUnit, RECEIVER, DEFAULT_EXECUTOR_BONUS);
        _warpPastDepositDelay();
        _wireBlacklist();
        _flag(RECEIVER);

        assertEq(_executeDepositMax(EXECUTOR, USER_A, nonce), 0, "a flagged receiver's max execution must no-op instead of reverting");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, nonce).assets), 10 * stUnit, "the request must stay queued untouched");
    }

    /// @notice A flagged owner cannot self-execute even to a distinct clean receiver, the owner screen freezes the request in both directions alongside the blocked cancel
    function test_executeDeposit_revertsOnFlaggedOwnerSelfExecutingToCleanReceiver() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(seniorTranche), 10 * stUnit, RECEIVER, 0);
        _warpPastDepositDelay();
        _wireBlacklist();
        _flag(USER_A);

        vm.expectRevert(_blacklistedError(USER_A));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(10 * stUnit));
    }

    /// @notice A flagged executor cannot trigger even a zero-bonus request, the operator screen binds regardless of whether any bonus value flows
    function test_executeDeposit_revertsOnFlaggedZeroBonusThirdPartyExecutor() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(seniorTranche), 10 * stUnit, USER_A, 0);
        _warpPastDepositDelay();
        _wireBlacklist();
        _flag(EXECUTOR);

        vm.expectRevert(_blacklistedError(EXECUTOR));
        vm.prank(EXECUTOR);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(10 * stUnit));
    }

    /// @notice A clean third party execution lands with its bonus once the executor is unblacklisted
    function test_executeDeposit_cleanThirdPartyExecutionLandsAfterUnblacklisting() public {
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(seniorTranche), 10 * stUnit);
        _warpPastDepositDelay();
        _wireBlacklist();
        _flag(EXECUTOR);
        roycoBlacklist.unblacklistAccounts(_one(EXECUTOR));

        uint256 executorAssetsBefore = IERC20Like(seniorTranche.asset()).balanceOf(EXECUTOR);
        assertGt(_executeDepositMax(EXECUTOR, USER_A, nonce), 0, "the unblacklisted executor must execute the deposit");
        assertGt(IERC20Like(seniorTranche.asset()).balanceOf(EXECUTOR), executorAssetsBefore, "the executor bonus must land");
    }

    // ---------------------------------------------------------------------
    // executeRedemption
    // ---------------------------------------------------------------------

    /// @notice A flagged third party executor cannot execute, the remittances settle outside the kernel's screened flows
    function test_executeRedemption_revertsOnFlaggedThirdPartyExecutor() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_A, DEFAULT_EXECUTOR_BONUS);
        _warpPastRedemptionDelay();
        _wireBlacklist();
        _flag(EXECUTOR);

        vm.expectRevert(_blacklistedError(EXECUTOR));
        vm.prank(EXECUTOR);
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);
    }

    /// @notice A receiver flagged after queueing cannot receive a third party remittance, the asset legs never route through the kernel
    function test_executeRedemption_revertsOnFlaggedReceiverInThirdPartyRemit() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, RECEIVER, DEFAULT_EXECUTOR_BONUS);
        _warpPastRedemptionDelay();
        _wireBlacklist();
        _flag(RECEIVER);

        vm.expectRevert(_blacklistedError(RECEIVER));
        vm.prank(EXECUTOR);
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);
    }

    /// @notice A flagged owner's request cannot be executed even by a clean keeper to a clean receiver, the owner screen freezes the escrow entirely while flagged
    function test_executeRedemption_revertsOnFlaggedOwnerExecutedByCleanKeeper() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, RECEIVER, DEFAULT_EXECUTOR_BONUS);
        _warpPastRedemptionDelay();
        _wireBlacklist();
        _flag(USER_A);

        vm.expectRevert(_blacklistedError(USER_A));
        vm.prank(EXECUTOR);
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);
    }

    /// @notice A flagged receiver on a self execution is stopped by the tranche redemption's kernel receiver screen
    function test_executeRedemption_flaggedReceiverStoppedByKernelRedeemScreenOnSelfExecution() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, RECEIVER, 0);
        _warpPastRedemptionDelay();
        _wireBlacklist();
        _flag(RECEIVER);

        vm.expectRevert(_blacklistedError(RECEIVER));
        vm.prank(USER_A);
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);
    }

    /// @notice A clean third party redemption lands with its bonus once the receiver is unblacklisted
    function test_executeRedemption_cleanThirdPartyExecutionLandsAfterUnblacklisting() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, RECEIVER, DEFAULT_EXECUTOR_BONUS);
        _warpPastRedemptionDelay();
        _wireBlacklist();
        _flag(RECEIVER);
        roycoBlacklist.unblacklistAccounts(_one(RECEIVER));

        uint256 receiverAssetsBefore = IERC20Like(seniorTranche.asset()).balanceOf(RECEIVER);
        uint256 executorAssetsBefore = IERC20Like(seniorTranche.asset()).balanceOf(EXECUTOR);
        vm.prank(EXECUTOR);
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);
        assertGt(IERC20Like(seniorTranche.asset()).balanceOf(RECEIVER), receiverAssetsBefore, "the receiver's remittance must land");
        assertGt(IERC20Like(seniorTranche.asset()).balanceOf(EXECUTOR), executorAssetsBefore, "the executor bonus must land");
    }

    // ---------------------------------------------------------------------
    // cancelDepositRequest
    // ---------------------------------------------------------------------

    /// @notice A flagged canceller cannot pull its escrowed assets, freezing a flagged user's escrow like its tranche shares
    function test_cancelDepositRequest_revertsOnFlaggedCanceller() public {
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(seniorTranche), 10 * stUnit);
        _wireBlacklist();
        _flag(USER_A);

        vm.expectRevert(_blacklistedError(USER_A));
        vm.prank(USER_A);
        entryPoint.cancelDepositRequest(nonce, USER_A);
    }

    /// @notice A flagged receiver cannot receive a cancelled deposit's escrowed assets, and unblacklisting releases them
    function test_cancelDepositRequest_revertsOnFlaggedReceiverAndReleasesOnClear() public {
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(seniorTranche), 10 * stUnit);
        _wireBlacklist();
        _flag(RECEIVER);

        vm.expectRevert(_blacklistedError(RECEIVER));
        vm.prank(USER_A);
        entryPoint.cancelDepositRequest(nonce, RECEIVER);

        // Unblacklisting releases the escrow to the receiver
        roycoBlacklist.unblacklistAccounts(_one(RECEIVER));
        uint256 receiverAssetsBefore = IERC20Like(seniorTranche.asset()).balanceOf(RECEIVER);
        _cancelDeposit(USER_A, nonce, RECEIVER);
        assertEq(IERC20Like(seniorTranche.asset()).balanceOf(RECEIVER), receiverAssetsBefore + 10 * stUnit, "the released escrow must land on the receiver");
    }

    // ---------------------------------------------------------------------
    // cancelRedemptionRequest
    // ---------------------------------------------------------------------

    /// @notice A flagged canceller cannot pull its escrowed shares, the canceller is not a party to the return transfer's kernel screen
    function test_cancelRedemptionRequest_revertsOnFlaggedCanceller() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_A, 0);
        _wireBlacklist();
        _flag(USER_A);

        vm.expectRevert(_blacklistedError(USER_A));
        vm.prank(USER_A);
        entryPoint.cancelRedemptionRequest(nonce, RECEIVER);
    }

    /// @notice A flagged receiver is stopped by the share escrow return's kernel screen, no entry point screen needed
    function test_cancelRedemptionRequest_flaggedReceiverStoppedByReturnTransferScreen() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_A, 0);
        _wireBlacklist();
        _flag(RECEIVER);

        vm.expectRevert(_blacklistedError(RECEIVER));
        vm.prank(USER_A);
        entryPoint.cancelRedemptionRequest(nonce, RECEIVER);

        // Unblacklisting releases the escrowed shares to the receiver
        roycoBlacklist.unblacklistAccounts(_one(RECEIVER));
        _cancelRedemption(USER_A, nonce, RECEIVER);
        assertEq(IERC20Like(address(seniorTranche)).balanceOf(RECEIVER), shares, "the released share escrow must land on the receiver");
    }

    // ---------------------------------------------------------------------
    // Live resolution and batch surfaces
    // ---------------------------------------------------------------------

    /// @notice The blacklist is resolved live through the kernel on every screen, a wiring after queueing still gates the request
    function test_screening_resolvesLiveBlacklistWiredAfterQueueing() public {
        // Queue with no blacklist configured at all
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(seniorTranche), 10 * stUnit);

        // Wire and flag afterward: the cancel must now be gated
        _wireBlacklist();
        _flag(USER_A);
        vm.expectRevert(_blacklistedError(USER_A));
        vm.prank(USER_A);
        entryPoint.cancelDepositRequest(nonce, USER_A);

        // Unwiring the blacklist restores the flow, pinning that nothing is cached on the request
        vm.prank(MARKET_OPS_ADMIN);
        kernel.setRoycoBlacklist(address(0));
        _cancelDeposit(USER_A, nonce, USER_A);
    }

    /// @notice The batch execution surface routes through the same per-request screening
    function test_executeDeposits_batchRevertsOnFlaggedReceiver() public {
        (uint256 nonceA,) = _requestDepositDefault(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonceB,) = _requestDeposit(USER_B, address(seniorTranche), 10 * stUnit, RECEIVER, DEFAULT_EXECUTOR_BONUS);
        _warpPastDepositDelay();
        _wireBlacklist();
        _flag(RECEIVER);

        address[] memory users = new address[](2);
        users[0] = USER_A;
        users[1] = USER_B;
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = nonceA;
        nonces[1] = nonceB;
        TRANCHE_UNIT[] memory assets = new TRANCHE_UNIT[](2);
        assets[0] = toTrancheUnits(10 * stUnit);
        assets[1] = toTrancheUnits(10 * stUnit);

        // The flagged receiver on the second request gates the whole explicit-amount batch through the per-request kernel mint screen
        vm.expectRevert(_blacklistedError(RECEIVER));
        vm.prank(EXECUTOR);
        entryPoint.executeDeposits(users, nonces, assets);
    }
}
