// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ChainlinkOracleClock } from "../../../src/entrypoint/clock/ChainlinkOracleClock.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { TRANCHE_UNIT, toTrancheUnits } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/// @dev TEMP repro for the "aggregator swap moves updatedAt backwards" finding
contract Test_TempAggSwapRepro is EntryPointTestBase {
    uint256 internal stUnit;
    ChainlinkOracleClock internal chainlinkClock;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
        chainlinkClock = new ChainlinkOracleClock(address(priceFeed));
    }

    function _setOracleClock(address _clock) internal {
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        for (uint256 i = 0; i < configs.length; ++i) {
            configs[i].oracleClock = _clock;
        }
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.modifyTrancheConfigs(tranches, configs);
    }

    /// Step 1: snapshot = T (old aggregator). Step 2: proxy swap -> updatedAt regresses to T-30.
    /// Step 3: delay matures, execution reverts. Step 4: new aggregator posts its first post-swap
    /// round (updatedAt = real posting time > T) -> gate opens.
    function test_repro_aggregatorSwap_backwardsUpdatedAt() public {
        _setOracleClock(address(chainlinkClock));
        uint64 T = chainlinkClock.poke();
        assertGt(T, 30, "fixture sanity");

        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        assertEq(entryPoint.getDepositRequest(USER_A, nonce).baseRequest.oracleClockSnapshot, T, "snapshot is old agg updatedAt");

        // Proxy swap: new aggregator's latest round is 30s OLDER than the old aggregator's last round
        priceFeed.setUpdatedAt(uint256(T) - 30);

        // Delay matures; gate is shut because poke() (T-30) is not > snapshot (T)
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        // COUNTERFACTUAL CHECK: even a FORWARD-but-not-past-snapshot value (poke() == T) blocks identically,
        // i.e. the block is not caused by the regression, it is the gate's normal wait-for-next-round.
        priceFeed.setUpdatedAt(uint256(T));
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        // First post-swap round from the NEW aggregator: updatedAt = actual posting block time, which is
        // necessarily > T (the swap happened after T in real time). The gate opens on it.
        priceFeed.setUpdatedAt(block.timestamp);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "first post-swap round opens the gate");
    }
}
