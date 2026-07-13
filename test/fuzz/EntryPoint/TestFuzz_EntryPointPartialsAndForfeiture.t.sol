// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";

/**
 * @title TestFuzz_EntryPointPartialsAndForfeiture
 * @notice Fuzzes the yield-neutrality property over PnL magnitudes and partial-execution splits: the requester
 *         never captures queued yield (their proceeds are pinned to the request-time NAV within rounding), splitting
 *         an execution never changes the total forfeited, and the nav snapshot's pro-rata scaling conserves value
 */
contract TestFuzz_EntryPointPartialsAndForfeiture is EntryPointTestBase {
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        _seedMarket(1000 * stUnit, 500 * stUnit);
        _deployEntryPoint();
    }

    /// @notice For any queued gain, the depositor's minted shares are worth the request-time NAV, never more
    function testFuzz_depositYieldNeutrality(uint256 _assets, uint256 _gainBps) public {
        _assets = bound(_assets, stUnit, 100 * stUnit);
        _gainBps = bound(_gainBps, 1, 5000);
        _checkDepositYieldNeutrality(_assets, _gainBps);
    }

    /// @notice Pins a once-failing fuzz counterexample: the JT's compounded effective yield (own PnL plus its share
    ///         of senior yield) must be captured by the forfeiture basis, not just the raw asset PnL
    /// @dev Deposit and redemption pins are separate tests: via-IR CSE caches block.timestamp within one test
    ///      function, so a second relative warp in the same test would silently no-op
    function test_depositYieldNeutrality_regressionCounterexample() public {
        _checkDepositYieldNeutrality(11_292_100_492_600_944_813, 141);
    }

    /// @notice The redemption half of the pinned counterexample (see the deposit pin above)
    function test_redemptionYieldNeutrality_regressionCounterexample() public {
        _checkRedemptionYieldNeutrality(11_292_100_492_600_944_813, 141);
    }

    function _checkDepositYieldNeutrality(uint256 _assets, uint256 _gainBps) internal {
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), _assets, USER_A, 0);
        uint256 navAtRequest = toUint256(entryPoint.getDepositRequest(USER_A, nonce).navAtRequestTime);

        applySTPnL(int256(_gainBps));
        _warpPastDepositDelay();
        uint256 userShares = _executeDepositMax(USER_A, USER_A, nonce);

        // The user's share value is pinned to the request-time NAV: forfeiture flooring may leave them dust above,
        // bounded by one share-wei of NAV, so assert the hard gain-direction ceiling plus a tight relative envelope
        uint256 userNav = toUint256(juniorTranche.convertToAssets(userShares).nav);
        assertLe(userNav, navAtRequest + toUint256(juniorTranche.convertToAssets(1).nav) + 1, "the depositor must never clear more than the snapshot plus rounding dust");
        assertApproxEqRel(userNav, navAtRequest, 0.001e18, "the depositor's proceeds must be pinned to the request-time NAV");
        assertGt(entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)), 0, "a queued gain must always forfeit");
    }

    /// @notice For any queued gain, the redeemer's claims are worth the request-time NAV, never more
    function testFuzz_redemptionYieldNeutrality(uint256 _assets, uint256 _gainBps) public {
        _assets = bound(_assets, stUnit, 100 * stUnit);
        _gainBps = bound(_gainBps, 1, 5000);
        _checkRedemptionYieldNeutrality(_assets, _gainBps);
    }

    function _checkRedemptionYieldNeutrality(uint256 _assets, uint256 _gainBps) internal {
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), _assets);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        uint256 navAtRequest = toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).navAtRequestTime);

        applySTPnL(int256(_gainBps));
        _warpPastRedemptionDelay();
        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);

        assertApproxEqRel(toUint256(claims.nav), navAtRequest, 0.001e18, "the redeemer's proceeds must be pinned to the request-time NAV");
        assertLe(toUint256(claims.nav), navAtRequest + toUint256(juniorTranche.convertToAssets(1).nav) + 1, "the redeemer must never clear more than the snapshot plus rounding dust");
    }

    /// @notice Splitting an execution into two arbitrary slices forfeits the same total as a single execution
    function testFuzz_partialSplit_forfeitureConservation(uint256 _assets, uint256 _splitBps, uint256 _gainBps) public {
        _assets = bound(_assets, stUnit, 50 * stUnit);
        _splitBps = bound(_splitBps, 100, 9900);
        _gainBps = bound(_gainBps, 100, 3000);

        // Two identical requests under identical PnL: one split, one single-shot
        (uint256 noncePartial,) = _requestDeposit(USER_A, address(juniorTranche), _assets, USER_A, 0);
        (uint256 nonceFull,) = _requestDeposit(USER_B, address(juniorTranche), _assets, USER_B, 0);

        applySTPnL(int256(_gainBps));
        _warpPastDepositDelay();

        uint256 slice = (_assets * _splitBps) / 10_000;
        if (slice == 0) slice = 1;
        _executeDeposit(USER_A, USER_A, noncePartial, slice);
        _executeDepositMax(USER_A, USER_A, noncePartial);
        uint256 forfeitedSplit = entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche));

        _executeDepositMax(USER_B, USER_B, nonceFull);
        uint256 forfeitedFull = entryPoint.getProtocolFeeSharesPendingCollection(address(juniorTranche)) - forfeitedSplit;

        // The split may differ from the single shot only by flooring dust (one wei per slice boundary)
        assertApproxEqAbs(forfeitedSplit, forfeitedFull, 2, "splitting an execution must not change the total forfeiture");
    }

    /// @notice The redemption nav snapshot's pro-rata scaling conserves value across any split
    function testFuzz_redemptionNavScaling_conservesSnapshot(uint256 _assets, uint256 _splitBps) public {
        _assets = bound(_assets, stUnit, 100 * stUnit);
        _splitBps = bound(_splitBps, 1, 9999);

        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), _assets);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        uint256 navBefore = toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).navAtRequestTime);
        _warpPastRedemptionDelay();

        uint256 slice = (shares * _splitBps) / 10_000;
        if (slice == 0) slice = 1;
        _executeRedemption(USER_A, USER_A, nonce, slice);

        // remaining snapshot == floor(navBefore * remainingShares / shares); the executed slice consumed the rest
        uint256 navAfter = toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).navAtRequestTime);
        uint256 expectedRemaining = (navBefore * (shares - slice)) / shares;
        assertEq(navAfter, expectedRemaining, "the remaining nav snapshot must be the floor-scaled pro-rata value");
    }
}
