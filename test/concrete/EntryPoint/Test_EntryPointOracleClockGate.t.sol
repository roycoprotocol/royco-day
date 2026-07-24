// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockPriceOracle } from "../../mocks/MockPriceOracle.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointOracleGate
 * @notice The collateral asset oracle execution gate: a request queued against a gated tranche can only execute
 *         once the market's oracle has observed at least one update AFTER the request, on top of the minimum delay,
 *         so execution always happens at max(request + delay, first post-request update)
 * @dev The gate closes the one hole a pure time delay leaves: with deviation/heartbeat-driven oracles, a request can
 *      mature before the next update lands and execute at the same stale mark it was requested at, ahead of a
 *      predictable update. Requiring one observed update inside the request lifecycle puts that update inside the
 *      forfeiture window. The delay floor remains as the defense against induced updates
 * @dev The oracle is resolved LIVE from the kernel on every poke, so the fixture drives the gate through the
 *      market's MockPriceOracle updatedAt knob and oracle rotation goes through kernel.setCollateralAssetOracle
 */
contract Test_EntryPointOracleGate is EntryPointTestBase {
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
    }

    /// @dev Rewrites all three tranche configs with the specified oracle gate state (everything else unchanged)
    function _setOracleGate(bool _enabled) internal {
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        for (uint256 i = 0; i < configs.length; ++i) {
            configs[i].gateByOracleUpdate = _enabled;
        }
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.modifyTrancheConfigs(tranches, configs);
    }

    /// @dev Rotates the market's collateral asset oracle to the specified replacement through the kernel admin surface
    function _rotateOracle(address _oracle) internal {
        vm.prank(ORACLE_QUOTER_ADMIN);
        kernel.setCollateralAssetOracle(_oracle, ORACLE_STALENESS_THRESHOLD_SECONDS, false);
    }

    // ---------------------------------------------------------------------
    // Request-time observation
    // ---------------------------------------------------------------------

    function test_request_stampsQueuedAtTimestamp() public {
        _setOracleGate(true);
        (uint256 depositNonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        assertEq(
            entryPoint.getDepositRequest(USER_A, depositNonce).baseRequest.queuedAtTimestamp,
            uint32(block.timestamp),
            "the deposit request must stamp its queueing time"
        );

        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 redemptionNonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        assertEq(
            entryPoint.getRedemptionRequest(USER_A, redemptionNonce).baseRequest.queuedAtTimestamp,
            uint32(block.timestamp),
            "the redemption request must stamp its queueing time"
        );
    }

    function test_request_withoutGate_stillStampsQueuedAtTimestamp() public {
        // The stamp carries no gate semantics of its own: it is always the queueing time, gated or not
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        assertEq(entryPoint.getDepositRequest(USER_A, nonce).baseRequest.queuedAtTimestamp, uint32(block.timestamp), "no gate must not skip the stamp");
    }

    // ---------------------------------------------------------------------
    // The gate: matured requests stay blocked until the oracle updates
    // ---------------------------------------------------------------------

    function test_maturedDepositRequest_blockedUntilOracleUpdates() public {
        _setOracleGate(true);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        // The delay elapses but the oracle never updates: the mark is the same one the request was placed at
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.COLLATERAL_ASSET_ORACLE_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        // The oracle updates: the post-request update is now priced into the mark, and execution opens
        collateralAssetOracle.setUpdatedAt(block.timestamp);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "execution must open once the oracle has updated");
    }

    function test_maturedRedemptionRequest_blockedUntilOracleUpdates() public {
        _setOracleGate(true);
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);

        vm.warp(block.timestamp + DEFAULT_REDEMPTION_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.COLLATERAL_ASSET_ORACLE_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);

        collateralAssetOracle.setUpdatedAt(block.timestamp);
        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);
        assertGt(toUint256(claims.nav), 0, "execution must open once the oracle has updated");
    }

    function test_updateBeforeDelay_delayFloorStillBinds() public {
        _setOracleGate(true);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        // The oracle updates immediately (or is induced to): the gate opens but the delay floor must still hold,
        // otherwise inducing an update would collapse the queue into a spot market
        vm.warp(block.timestamp + 10);
        collateralAssetOracle.setUpdatedAt(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.INVALID_REQUEST.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));
    }

    // ---------------------------------------------------------------------
    // Configuration transitions and escapes
    // ---------------------------------------------------------------------

    function test_disabledGate_isPureDelayMode() public {
        // Default configs leave the gate disabled: the delay alone gates execution, with no oracle-update requirement
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "an ungated tranche must execute on the delay alone");
    }

    function test_adminDisablingGate_degradesInFlightRequestsToPureDelay() public {
        _setOracleGate(true);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        _setOracleGate(false);

        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "disabling the gate must degrade in-flight requests to pure-delay gating");
    }

    function test_adminEnablingGateMidFlight_gatesPriorRequests() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        _setOracleGate(true);

        // Enabling the gate expresses the intent to price pending information before execution: requests placed
        // before the gate hold to the same rule, since the queueing stamp carries no gate lineage
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.COLLATERAL_ASSET_ORACLE_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        // A genuine post-request update opens the pre-gate request like any other
        collateralAssetOracle.setUpdatedAt(block.timestamp);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "a post-request update must open requests placed before the gate was enabled");
    }

    function test_modifyTrancheConfigs_rejectsFutureReportingOracle() public {
        // An oracle reporting a future update timestamp would satisfy the execution gate without a genuine update:
        // the configuration must fail shut on the one half of oracle honesty that is checkable on-chain
        collateralAssetOracle.setUpdatedAt(block.timestamp + 1 days);
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        for (uint256 i = 0; i < configs.length; ++i) {
            configs[i].gateByOracleUpdate = true;
        }
        vm.expectRevert(IRoycoDayEntryPoint.COLLATERAL_ASSET_ORACLE_IN_THE_FUTURE.selector);
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.modifyTrancheConfigs(tranches, configs);
    }

    function test_request_rejectsFutureReportingOracle() public {
        // The oracle turns future-reporting after the gate is enabled (e.g. a migration to a broken feed): the
        // request-time poke must fail shut rather than queue against an oracle that can falsely open the gate
        _setOracleGate(true);
        collateralAssetOracle.setUpdatedAt(block.timestamp + 1 days);

        vm.expectRevert(IRoycoDayEntryPoint.COLLATERAL_ASSET_ORACLE_IN_THE_FUTURE.selector);
        vm.prank(USER_A);
        entryPoint.requestDeposit(address(juniorTranche), toTrancheUnits(10 * stUnit), USER_A, 0);
    }

    function test_deadOracle_executionWaitsForRevival() public {
        // The oracle dies after the request (a zero update timestamp): a zero reading cannot weaken the gate, it
        // conservatively holds execution shut until the oracle revives with a genuine update
        _setOracleGate(true);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        collateralAssetOracle.setUpdatedAt(0);

        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.COLLATERAL_ASSET_ORACLE_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        collateralAssetOracle.setUpdatedAt(block.timestamp);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "the oracle's revival must reopen execution");
    }

    function test_cancellation_isUngatedWhileExecutionIsBlocked() public {
        _setOracleGate(true);
        uint256 amount = 10 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);

        // Matured but gate-blocked: the escrow must still be recoverable, the gate guards entry, never exit
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        uint256 balanceBefore = stJtVault.balanceOf(USER_A);
        _cancelDeposit(USER_A, nonce, USER_A);
        assertEq(stJtVault.balanceOf(USER_A) - balanceBefore, amount, "cancellation must return the escrow while the gate is shut");
    }

    function test_updateBeforeDelay_delayFloorStillBinds_redemption() public {
        _setOracleGate(true);
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);

        // The oracle updates immediately: the gate opens but the redemption delay floor must still hold
        vm.warp(block.timestamp + 10);
        collateralAssetOracle.setUpdatedAt(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.INVALID_REQUEST.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);
    }

    function test_requestRedemption_rejectsFutureReportingOracle() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        _setOracleGate(true);
        collateralAssetOracle.setUpdatedAt(block.timestamp + 1 days);

        vm.expectRevert(IRoycoDayEntryPoint.COLLATERAL_ASSET_ORACLE_IN_THE_FUTURE.selector);
        vm.prank(USER_A);
        entryPoint.requestRedemption(address(juniorTranche), shares, USER_A, 0, IRoycoDayEntryPoint.RedemptionMode.INKIND);
    }

    // ---------------------------------------------------------------------
    // The permissionless poke surface and its event
    // ---------------------------------------------------------------------

    function test_pokeCollateralAssetOracle_isPermissionlessAndDrivesTheGate() public {
        _setOracleGate(true);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        // A post-request update lands and ANYONE observes it through the entry point, emitting the poke event
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        collateralAssetOracle.setUpdatedAt(block.timestamp);
        vm.expectEmit(address(entryPoint));
        emit IRoycoDayEntryPoint.CollateralAssetOraclePoked(address(juniorTranche), uint32(block.timestamp));
        vm.prank(makeAddr("ANYONE"));
        uint32 lastUpdatedAt = entryPoint.pokeCollateralAssetOracle(address(juniorTranche));
        assertEq(lastUpdatedAt, uint32(block.timestamp), "the poke must report the fresh update");

        // The observed post-request update satisfies the gate: execution opens
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "an observed post-request update must open the gate");
    }

    function test_pokeCollateralAssetOracle_ungatedTranche_isANoOpReportingZero() public {
        // Default configs leave the gate disabled: the poke must not revert, must consult nothing, and must emit nothing
        vm.recordLogs();
        assertEq(entryPoint.pokeCollateralAssetOracle(address(juniorTranche)), 0, "an ungated tranche must report a zero timestamp");
        assertEq(vm.getRecordedLogs().length, 0, "an ungated poke must emit nothing");
    }

    function test_request_emitsCollateralAssetOraclePoked() public {
        // The request-time poke refreshes the oracle and announces the reading it lands on
        _setOracleGate(true);
        collateralAssetOracle.setUpdatedAt(block.timestamp);

        // Fund and approve first: the emit expectation must bind to the request call itself
        uint256 amount = 10 * stUnit;
        _fundTrancheAssets(USER_A, address(juniorTranche), amount);
        vm.startPrank(USER_A);
        stJtVault.approve(address(entryPoint), amount);
        vm.expectEmit(address(entryPoint));
        emit IRoycoDayEntryPoint.CollateralAssetOraclePoked(address(juniorTranche), uint32(block.timestamp));
        entryPoint.requestDeposit(address(juniorTranche), toTrancheUnits(amount), USER_A, 0);
        vm.stopPrank();
    }

    function test_execution_rejectsFutureReportingOracle() public {
        // The execution-gate poke is where the future check is load-bearing: a future timestamp trivially
        // satisfies the strictly-after comparison, so it must fail shut before the gate ever reads it
        _setOracleGate(true);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        collateralAssetOracle.setUpdatedAt(block.timestamp + 1 days);

        vm.expectRevert(IRoycoDayEntryPoint.COLLATERAL_ASSET_ORACLE_IN_THE_FUTURE.selector);
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        // The standalone poke fails shut on the same oracle
        vm.expectRevert(IRoycoDayEntryPoint.COLLATERAL_ASSET_ORACLE_IN_THE_FUTURE.selector);
        entryPoint.pokeCollateralAssetOracle(address(juniorTranche));

        // An honest update reopens execution
        collateralAssetOracle.setUpdatedAt(block.timestamp);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "an honest update must reopen execution");
    }

    function test_configAndExecutionPokes_emitCollateralAssetOraclePoked() public {
        // Explicit timestamp locals: the emit templates must not read block.timestamp across the warp, the
        // via-IR optimizer may reuse a pre-warp evaluation of the same expression within one test frame
        uint256 configuredAt = block.timestamp;
        collateralAssetOracle.setUpdatedAt(configuredAt);

        // The config-time poke announces the reading for each tranche it validates
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        for (uint256 i = 0; i < configs.length; ++i) {
            configs[i].gateByOracleUpdate = true;
        }
        vm.expectEmit(address(entryPoint));
        emit IRoycoDayEntryPoint.CollateralAssetOraclePoked(tranches[0], uint32(configuredAt));
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.modifyTrancheConfigs(tranches, configs);

        // The execution-gate poke announces the reading it opened on
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        uint256 executedAt = configuredAt + DEFAULT_DEPOSIT_DELAY + 1;
        vm.warp(executedAt);
        collateralAssetOracle.setUpdatedAt(executedAt);
        vm.expectEmit(address(entryPoint));
        emit IRoycoDayEntryPoint.CollateralAssetOraclePoked(address(juniorTranche), uint32(executedAt));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));
    }

    // ---------------------------------------------------------------------
    // Oracle rotation: no pending request may open without a genuine update
    // ---------------------------------------------------------------------

    function test_rotationToOracleWithoutPostRequestUpdate_cannotInstantOpenPendingQueue() public {
        // A queue pending under one oracle, rotated to a replacement whose last update is not after the request:
        // the rotation itself cannot open a single pending request, the queue holds until a genuine update lands
        _setOracleGate(true);
        uint256 queuedAt = block.timestamp;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        MockPriceOracle replacement = new MockPriceOracle(address(stJtVault), cell.collateralAsset.initialRateWAD);
        replacement.setUpdatedAt(queuedAt);
        _rotateOracle(address(replacement));

        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.COLLATERAL_ASSET_ORACLE_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        // The replacement's first genuine post-request update is resolved live from the kernel: the queue resumes
        replacement.setUpdatedAt(block.timestamp);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "the replacement oracle's first genuine update must reopen the queue");
    }

    function test_rotationToOracleWithPostRequestUpdate_opensImmediately() public {
        // The rotated-in oracle already carries an update stamped AFTER the request was queued: that is a genuine
        // post-request source update, so the pending request opens immediately, correct, not a hole
        _setOracleGate(true);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        MockPriceOracle replacement = new MockPriceOracle(address(stJtVault), cell.collateralAsset.initialRateWAD);
        _rotateOracle(address(replacement));

        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "a genuine post-request update on the rotated-in oracle must open the request");
    }

    function test_sameSecondUpdate_staysBlocked_strictInequality() public {
        // An update stamped in the very second the request queued is not provably after it: the strict inequality
        // holds the gate shut until an update lands in a strictly later second
        _setOracleGate(true);
        collateralAssetOracle.setUpdatedAt(block.timestamp);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.COLLATERAL_ASSET_ORACLE_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        collateralAssetOracle.setUpdatedAt(block.timestamp);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "a strictly later update must open the gate");
    }

    function test_adminDisablingGate_degradesInFlightRedemptionsToPureDelay() public {
        _setOracleGate(true);
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        _setOracleGate(false);

        vm.warp(block.timestamp + DEFAULT_REDEMPTION_DELAY + 1);
        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);
        assertGt(toUint256(claims.nav), 0, "disabling the gate must degrade in-flight redemptions to pure-delay gating");
    }

    function test_adminEnablingGateMidFlight_gatesPriorRedemptions() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        _setOracleGate(true);

        vm.warp(block.timestamp + DEFAULT_REDEMPTION_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.COLLATERAL_ASSET_ORACLE_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);

        collateralAssetOracle.setUpdatedAt(block.timestamp);
        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);
        assertGt(toUint256(claims.nav), 0, "a post-request update must open redemptions placed before the gate was enabled");
    }

    function test_blockedRedemption_poisonsBatchLikeAnUnmaturedOne() public {
        _setOracleGate(true);
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);

        vm.warp(block.timestamp + DEFAULT_REDEMPTION_DELAY + 1);
        address[] memory users = new address[](1);
        users[0] = USER_A;
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = nonce;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;

        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.COLLATERAL_ASSET_ORACLE_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeRedemptions(users, nonces, amounts);
    }

    function test_blockedRequest_poisonsBatchLikeAnUnmaturedOne() public {
        _setOracleGate(true);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        address[] memory users = new address[](1);
        users[0] = USER_A;
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = nonce;
        TRANCHE_UNIT[] memory amounts = new TRANCHE_UNIT[](1);
        amounts[0] = toTrancheUnits(type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.COLLATERAL_ASSET_ORACLE_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposits(users, nonces, amounts);
    }
}
