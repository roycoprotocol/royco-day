// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase, IERC20Like } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointRequestExpiration
 * @notice Request expiry: a deposit or redemption is executable only inside the half-open window
 *         [executableAtTimestamp, expiresAtTimestamp). Once the window elapses the request is terminal — every
 *         execution path (explicit amount and the MAX sentinel that gracefully skips market-gated requests) reverts,
 *         and the only remaining action is cancellation, which always returns the escrow. The resolved expiry
 *         saturates at type(uint32).max, so a maximal window means the request effectively never expires
 * @dev Deposits exercise the junior tranche and redemptions the senior tranche (both serve freely in a 100/30
 *      PERPETUAL seed). Delays stay at the fixture defaults (1h); expiry windows are armed per-test via _setTrancheExpiry
 */
contract Test_EntryPointRequestExpiration is EntryPointTestBase {
    uint256 internal stUnit;

    /// @dev Execution-window length armed on top of the default delays for the expiring-request tests
    uint32 internal constant DEP_EXPIRY = 2 hours;
    uint32 internal constant RED_EXPIRY = 2 hours;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        _seedMarket(100 * stUnit, 30 * stUnit);
        _deployEntryPoint();
    }

    // ---------------------------------------------------------------------
    // Deposits
    // ---------------------------------------------------------------------

    function test_deposit_setsExpiryTimestampOneWindowPastExecutable() public {
        _setTrancheExpiry(address(juniorTranche), DEP_EXPIRY, RED_EXPIRY);
        (uint256 nonce, uint32 executableAt) = _requestDeposit(USER_A, address(juniorTranche), 5 * stUnit, USER_A, 0);
        assertEq(
            entryPoint.getDepositRequest(USER_A, nonce).baseRequest.expiresAtTimestamp,
            executableAt + DEP_EXPIRY,
            "the deposit expiry must sit exactly one window past the executable timestamp"
        );
    }

    /// @notice Both request functions return the resolved expiry alongside the nonce and executable timestamp, matching storage
    function test_requestFunctions_returnExpiresAtTimestamp() public {
        _setTrancheExpiry(address(juniorTranche), DEP_EXPIRY, RED_EXPIRY);

        // Deposit: fund and approve, then call the entry point directly to capture all three returns
        uint256 amount = 5 * stUnit;
        _fundTrancheAssets(USER_A, address(juniorTranche), amount);
        vm.startPrank(USER_A);
        IERC20Like(juniorTranche.asset()).approve(address(entryPoint), amount);
        (uint256 depositNonce, uint32 depositExecutableAt, uint32 depositExpiresAt) =
            entryPoint.requestDeposit(address(juniorTranche), toTrancheUnits(amount), USER_A, 0);
        vm.stopPrank();
        assertEq(depositExpiresAt, depositExecutableAt + DEP_EXPIRY, "the returned deposit expiry must sit one window past the executable timestamp");
        assertEq(
            entryPoint.getDepositRequest(USER_A, depositNonce).baseRequest.expiresAtTimestamp, depositExpiresAt, "the returned deposit expiry must match storage"
        );

        // Redemption: escrow shares and capture all three returns
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), amount);
        vm.startPrank(USER_A);
        IERC20Like(address(juniorTranche)).approve(address(entryPoint), shares);
        (uint256 redemptionNonce, uint32 redemptionExecutableAt, uint32 redemptionExpiresAt) =
            entryPoint.requestRedemption(address(juniorTranche), shares, USER_A, 0, IRoycoDayEntryPoint.RedemptionMode.INKIND);
        vm.stopPrank();
        assertEq(
            redemptionExpiresAt, redemptionExecutableAt + RED_EXPIRY, "the returned redemption expiry must sit one window past the executable timestamp"
        );
        assertEq(
            entryPoint.getRedemptionRequest(USER_A, redemptionNonce).baseRequest.expiresAtTimestamp,
            redemptionExpiresAt,
            "the returned redemption expiry must match storage"
        );
    }

    function test_deposit_maximalWindow_saturatesToMaxTimestamp() public {
        // The fixture default is a maximal window: the resolved expiry saturates at type(uint32).max (never arrives)
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 5 * stUnit, USER_A, 0);
        assertEq(
            entryPoint.getDepositRequest(USER_A, nonce).baseRequest.expiresAtTimestamp,
            type(uint32).max,
            "a maximal expiry window must saturate the timestamp at type(uint32).max"
        );
    }

    function test_deposit_withinWindow_executes() public {
        _setTrancheExpiry(address(juniorTranche), DEP_EXPIRY, RED_EXPIRY);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 5 * stUnit, USER_A, 0);
        _warpPastDepositDelay(); // now inside [executableAt, expiresAt)
        assertGt(_executeDepositMax(USER_A, USER_A, nonce), 0, "a request executed inside its window must mint shares");
    }

    function test_deposit_afterExpiry_explicitExecuteReverts() public {
        _setTrancheExpiry(address(juniorTranche), DEP_EXPIRY, RED_EXPIRY);
        uint256 amount = 5 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);
        _warpAndRefreshFeed(uint256(DEFAULT_DEPOSIT_DELAY) + DEP_EXPIRY + 1);
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.REQUEST_EXPIRED.selector, nonce));
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(amount));
    }

    function test_deposit_afterExpiry_maxSentinelExecuteReverts() public {
        _setTrancheExpiry(address(juniorTranche), DEP_EXPIRY, RED_EXPIRY);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 5 * stUnit, USER_A, 0);
        _warpAndRefreshFeed(uint256(DEFAULT_DEPOSIT_DELAY) + DEP_EXPIRY + 1);
        // Expiry is terminal: unlike a market-gated request, the MAX sentinel must NOT gracefully skip — it reverts
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.REQUEST_EXPIRED.selector, nonce));
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));
    }

    function test_deposit_exactlyAtExpiry_isExpired() public {
        _setTrancheExpiry(address(juniorTranche), DEP_EXPIRY, RED_EXPIRY);
        uint256 amount = 5 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);
        uint32 expiresAt = entryPoint.getDepositRequest(USER_A, nonce).baseRequest.expiresAtTimestamp;
        // Land exactly on the boundary: the window is half-open [executableAt, expiresAt), so this is already expired
        _warpAndRefreshFeed(uint256(expiresAt) - block.timestamp);
        assertEq(block.timestamp, uint256(expiresAt), "sanity: now sits exactly on the expiry boundary");
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.REQUEST_EXPIRED.selector, nonce));
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(amount));
    }

    function test_deposit_afterExpiry_canStillCancel() public {
        _setTrancheExpiry(address(juniorTranche), DEP_EXPIRY, RED_EXPIRY);
        uint256 amount = 5 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);
        _warpAndRefreshFeed(uint256(DEFAULT_DEPOSIT_DELAY) + DEP_EXPIRY + 1);
        address asset = entryPoint.getTrancheConfig(address(juniorTranche)).asset;
        uint256 balBefore = IERC20Like(asset).balanceOf(USER_A);
        _cancelDeposit(USER_A, nonce, USER_A);
        assertEq(IERC20Like(asset).balanceOf(USER_A) - balBefore, amount, "an expired deposit must still return its escrow on cancel");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, nonce).assets), 0, "the cancelled request must be cleared");
    }

    function test_deposit_maximalWindow_executesFarInFuture() public {
        // No _setTrancheExpiry call: the window stays maximal (saturated expiry never arrives)
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 5 * stUnit, USER_A, 0);
        _warpAndRefreshFeed(2 days);
        assertGt(_executeDepositMax(USER_A, USER_A, nonce), 0, "a request with a maximal expiry window must stay executable arbitrarily far in the future");
    }

    function test_deposit_partialThenExpiry_remainderOnlyCancellable() public {
        _setTrancheExpiry(address(juniorTranche), DEP_EXPIRY, RED_EXPIRY);
        uint256 amount = 6 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);
        _warpPastDepositDelay();
        // An explicit partial execution leaves a remainder that inherits the original request's expiry window
        assertGt(_executeDeposit(USER_A, USER_A, nonce, 2 * stUnit), 0, "the partial execution must mint shares");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, nonce).assets), 4 * stUnit, "the unfilled remainder must persist");

        // Once the shared window elapses the remainder is terminal and can no longer be executed
        _warpAndRefreshFeed(DEP_EXPIRY);
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.REQUEST_EXPIRED.selector, nonce));
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(2 * stUnit));

        // But it can still be cancelled, returning the unfilled escrow
        address asset = entryPoint.getTrancheConfig(address(juniorTranche)).asset;
        uint256 balBefore = IERC20Like(asset).balanceOf(USER_A);
        _cancelDeposit(USER_A, nonce, USER_A);
        assertEq(IERC20Like(asset).balanceOf(USER_A) - balBefore, 4 * stUnit, "the expired remainder must still be cancellable");
    }

    // ---------------------------------------------------------------------
    // Redemptions
    // ---------------------------------------------------------------------

    function test_redemption_setsExpiryTimestampOneWindowPastExecutable() public {
        _setTrancheExpiry(address(seniorTranche), DEP_EXPIRY, RED_EXPIRY);
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce, uint32 executableAt) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_A, 0);
        assertEq(
            entryPoint.getRedemptionRequest(USER_A, nonce).baseRequest.expiresAtTimestamp,
            executableAt + RED_EXPIRY,
            "the redemption expiry must sit exactly one window past the executable timestamp"
        );
    }

    function test_redemption_withinWindow_executes() public {
        _setTrancheExpiry(address(seniorTranche), DEP_EXPIRY, RED_EXPIRY);
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_A, 0);
        _warpPastRedemptionDelay(); // now inside [executableAt, expiresAt)
        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);
        assertGt(toUint256(claims.nav), 0, "a redemption executed inside its window must deliver claims");
    }

    function test_redemption_afterExpiry_explicitExecuteReverts() public {
        _setTrancheExpiry(address(seniorTranche), DEP_EXPIRY, RED_EXPIRY);
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_A, 0);
        _warpAndRefreshFeed(uint256(DEFAULT_REDEMPTION_DELAY) + RED_EXPIRY + 1);
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.REQUEST_EXPIRED.selector, nonce));
        entryPoint.executeRedemption(USER_A, nonce, shares);
    }

    function test_redemption_afterExpiry_maxSentinelExecuteReverts() public {
        _setTrancheExpiry(address(seniorTranche), DEP_EXPIRY, RED_EXPIRY);
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_A, 0);
        _warpAndRefreshFeed(uint256(DEFAULT_REDEMPTION_DELAY) + RED_EXPIRY + 1);
        // Expiry is terminal: the MAX sentinel reverts rather than gracefully skipping
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.REQUEST_EXPIRED.selector, nonce));
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);
    }

    function test_redemption_afterExpiry_canStillCancel() public {
        _setTrancheExpiry(address(seniorTranche), DEP_EXPIRY, RED_EXPIRY);
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_A, 0);
        _warpAndRefreshFeed(uint256(DEFAULT_REDEMPTION_DELAY) + RED_EXPIRY + 1);
        uint256 balBefore = IERC20Like(address(seniorTranche)).balanceOf(USER_A);
        _cancelRedemption(USER_A, nonce, USER_A);
        assertEq(
            IERC20Like(address(seniorTranche)).balanceOf(USER_A) - balBefore, shares, "an expired redemption must still return its escrowed shares on cancel"
        );
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonce).shares, 0, "the cancelled request must be cleared");
    }

    function test_redemption_maximalWindow_executesFarInFuture() public {
        // No _setTrancheExpiry call: the window stays maximal (saturated expiry never arrives)
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_A, 0);
        _warpAndRefreshFeed(2 days);
        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);
        assertGt(toUint256(claims.nav), 0, "a redemption with a maximal expiry window must stay executable arbitrarily far in the future");
    }

    function test_redemption_partialThenExpiry_remainderOnlyCancellable() public {
        _setTrancheExpiry(address(seniorTranche), DEP_EXPIRY, RED_EXPIRY);
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_A, 0);
        _warpPastRedemptionDelay();
        // An explicit partial redemption leaves a remainder that inherits the original request's expiry window
        uint256 firstLeg = shares / 2;
        AssetClaims memory claims = _executeRedemption(USER_A, USER_A, nonce, firstLeg);
        assertGt(toUint256(claims.nav), 0, "the partial redemption must deliver claims");
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonce).shares, shares - firstLeg, "the unfilled remainder must persist");

        // Once the shared window elapses the remainder is terminal and can no longer be executed
        _warpAndRefreshFeed(RED_EXPIRY);
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.REQUEST_EXPIRED.selector, nonce));
        entryPoint.executeRedemption(USER_A, nonce, shares - firstLeg);

        // But it can still be cancelled, returning the unfilled share escrow
        uint256 balBefore = IERC20Like(address(seniorTranche)).balanceOf(USER_A);
        _cancelRedemption(USER_A, nonce, USER_A);
        assertEq(IERC20Like(address(seniorTranche)).balanceOf(USER_A) - balBefore, shares - firstLeg, "the expired remainder must still be cancellable");
    }

    // ---------------------------------------------------------------------
    // Expiry x executor bonus
    // ---------------------------------------------------------------------

    /// @notice Expiry is terminal regardless of the executor bonus: both the third party and the owner are locked
    ///         out, and cancellation returns the FULL escrow (the bonus never leaks a slice of an expired request)
    function test_deposit_expiryWithBonus_terminalForAllExecutors_cancelReturnsFullEscrow() public {
        _setTrancheExpiry(address(juniorTranche), DEP_EXPIRY, RED_EXPIRY);
        uint256 amount = 5 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, DEFAULT_EXECUTOR_BONUS);
        _warpAndRefreshFeed(uint256(DEFAULT_DEPOSIT_DELAY) + DEP_EXPIRY + 1);

        // Third-party and self execution are both terminally locked out
        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.REQUEST_EXPIRED.selector, nonce));
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.REQUEST_EXPIRED.selector, nonce));
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(amount));

        // Cancellation returns the full asset escrow: no bonus was ever carved out
        address asset = entryPoint.getTrancheConfig(address(juniorTranche)).asset;
        uint256 balBefore = IERC20Like(asset).balanceOf(USER_A);
        _cancelDeposit(USER_A, nonce, USER_A);
        assertEq(IERC20Like(asset).balanceOf(USER_A) - balBefore, amount, "the expired bonus-bearing deposit must return its full escrow on cancel");
        assertEq(IERC20Like(asset).balanceOf(EXECUTOR), 0, "no bonus may leak from an expired request");
    }

    /// @notice Redemption mirror: an expired bonus-bearing redemption is terminal for everyone and cancels whole
    function test_redemption_expiryWithBonus_terminalForAllExecutors_cancelReturnsFullEscrow() public {
        _setTrancheExpiry(address(seniorTranche), DEP_EXPIRY, RED_EXPIRY);
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_A, DEFAULT_EXECUTOR_BONUS);
        _warpAndRefreshFeed(uint256(DEFAULT_REDEMPTION_DELAY) + RED_EXPIRY + 1);

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.REQUEST_EXPIRED.selector, nonce));
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.REQUEST_EXPIRED.selector, nonce));
        entryPoint.executeRedemption(USER_A, nonce, shares);

        uint256 balBefore = IERC20Like(address(seniorTranche)).balanceOf(USER_A);
        _cancelRedemption(USER_A, nonce, USER_A);
        assertEq(IERC20Like(address(seniorTranche)).balanceOf(USER_A) - balBefore, shares, "the expired bonus-bearing redemption must return its full share escrow");
        assertEq(IERC20Like(address(seniorTranche)).balanceOf(EXECUTOR), 0, "no bonus may leak from an expired request");
    }

    /// @notice A third-party partial fill followed by expiry: the filled slice's bonus is settled and stays settled,
    ///         the remainder is cancel-only
    function test_deposit_partialBonusThenExpiry_remainderCancelOnly_bonusStandsOnFilledSlice() public {
        _setTrancheExpiry(address(juniorTranche), DEP_EXPIRY, RED_EXPIRY);
        uint256 amount = 6 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, DEFAULT_EXECUTOR_BONUS);
        _warpPastDepositDelay();

        // The executor fills a third of the escrow inside the window and earns its share slice of that fill
        uint256 slice = amount / 3;
        uint256 userShares = _executeDeposit(EXECUTOR, USER_A, nonce, slice);
        uint256 expectedBonus = (userShares * DEFAULT_EXECUTOR_BONUS) / 1e18;
        assertEq(juniorTranche.balanceOf(EXECUTOR), expectedBonus, "the filled slice's bonus must settle in shares");

        // The window elapses: the remainder is terminal for both parties
        _warpAndRefreshFeed(DEP_EXPIRY);
        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.REQUEST_EXPIRED.selector, nonce));
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        // Cancellation returns exactly the unfilled escrow; the settled bonus is untouched
        address asset = entryPoint.getTrancheConfig(address(juniorTranche)).asset;
        uint256 balBefore = IERC20Like(asset).balanceOf(USER_A);
        _cancelDeposit(USER_A, nonce, USER_A);
        assertEq(IERC20Like(asset).balanceOf(USER_A) - balBefore, amount - slice, "the expired remainder must return exactly the unfilled escrow");
        assertEq(juniorTranche.balanceOf(EXECUTOR), expectedBonus, "the settled bonus must be untouched by the cancellation");
    }

    // ---------------------------------------------------------------------
    // Expiry x batches
    // ---------------------------------------------------------------------

    /// @notice One expired request poisons a whole execution batch (mirroring the unmatured/oracle-blocked poisoning):
    ///         the batch loop reverts REQUEST_EXPIRED rather than skipping the terminal entry
    function test_batchExecution_oneExpiredRequestPoisonsTheBatch() public {
        _setTrancheExpiry(address(juniorTranche), DEP_EXPIRY, RED_EXPIRY);
        // Request A first; request B mid-window so A expires while B is live and executable
        (uint256 nonceA,) = _requestDeposit(USER_A, address(juniorTranche), 2 * stUnit, USER_A, 0);
        _warpAndRefreshFeed(uint256(DEFAULT_DEPOSIT_DELAY) + DEP_EXPIRY / 2);
        (uint256 nonceB,) = _requestDeposit(USER_B, address(juniorTranche), 2 * stUnit, USER_B, 0);
        // Now: A past its expiry, B past its delay and inside its window
        _warpAndRefreshFeed(uint256(DEFAULT_DEPOSIT_DELAY) + DEP_EXPIRY / 2 + 1);
        assertGe(block.timestamp, entryPoint.getDepositRequest(USER_A, nonceA).baseRequest.expiresAtTimestamp, "setup: A must be expired");
        assertLt(block.timestamp, entryPoint.getDepositRequest(USER_B, nonceB).baseRequest.expiresAtTimestamp, "setup: B must still be live");

        address[] memory users = new address[](2);
        users[0] = USER_B;
        users[1] = USER_A;
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = nonceB;
        nonces[1] = nonceA;
        TRANCHE_UNIT[] memory amounts = new TRANCHE_UNIT[](2);
        amounts[0] = toTrancheUnits(type(uint256).max);
        amounts[1] = toTrancheUnits(type(uint256).max);

        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.REQUEST_EXPIRED.selector, nonceA));
        entryPoint.executeDeposits(users, nonces, amounts);

        // The live request alone still executes
        assertGt(_executeDepositMax(USER_B, USER_B, nonceB), 0, "the live request must execute once the poisoned batch is split");
    }

    // ---------------------------------------------------------------------
    // Expiry x config changes
    // ---------------------------------------------------------------------

    /// @notice The stored expiry is immutable: re-configuring the tranche's window never moves an in-flight request's
    ///         expiresAtTimestamp — only new requests pick the new window up
    function test_configChange_doesNotMoveInFlightExpiry() public {
        _setTrancheExpiry(address(juniorTranche), DEP_EXPIRY, RED_EXPIRY);
        (uint256 nonce, uint32 executableAt) = _requestDeposit(USER_A, address(juniorTranche), 5 * stUnit, USER_A, 0);
        uint32 storedExpiry = entryPoint.getDepositRequest(USER_A, nonce).baseRequest.expiresAtTimestamp;
        assertEq(storedExpiry, executableAt + DEP_EXPIRY, "sanity: the request must carry the original window");

        // Shrink the tranche's window to a quarter: the in-flight request keeps its stored expiry
        _setTrancheExpiry(address(juniorTranche), DEP_EXPIRY / 4, RED_EXPIRY / 4);
        assertEq(
            entryPoint.getDepositRequest(USER_A, nonce).baseRequest.expiresAtTimestamp, storedExpiry, "a config change must never move an in-flight expiry"
        );

        // Execution honors the STORED window: warp past the would-be shorter expiry but inside the original one
        _warpAndRefreshFeed(uint256(DEFAULT_DEPOSIT_DELAY) + DEP_EXPIRY / 2);
        assertGt(block.timestamp, uint256(executableAt) + DEP_EXPIRY / 4, "sanity: past the would-be shorter window");
        assertGt(_executeDepositMax(USER_A, USER_A, nonce), 0, "the in-flight request must execute inside its original window");

        // A fresh request picks up the new, shorter window
        (uint256 freshNonce, uint32 freshExecutableAt) = _requestDeposit(USER_A, address(juniorTranche), 5 * stUnit, USER_A, 0);
        assertEq(
            entryPoint.getDepositRequest(USER_A, freshNonce).baseRequest.expiresAtTimestamp,
            freshExecutableAt + DEP_EXPIRY / 4,
            "a fresh request must carry the re-configured window"
        );
    }
}
