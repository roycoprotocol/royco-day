// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
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
}
