// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { MockCheckpointClock } from "../../mocks/MockCheckpointClock.sol";
import { MockValueSource } from "../../mocks/MockValueSource.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { toTrancheUnits } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

contract Scratch_MisscaledDeviation is EntryPointTestBase {
    uint256 internal stUnit;
    MockValueSource internal source;
    MockCheckpointClock internal clock;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
        source = new MockValueSource(1e18);
        // Admin intends "2%" but passes 2e18 instead of 0.02e18 — constructor accepts silently
        clock = new MockCheckpointClock(address(source), 2e18);
    }

    function _setOracleClock(address _clock) internal {
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        for (uint256 i = 0; i < configs.length; ++i) {
            configs[i].oracleClock = _clock;
        }
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.modifyTrancheConfigs(tranches, configs);
    }

    function test_scratch_misscaledThreshold_neverTicksOnDownMoves() public {
        uint64 seeded = clock.lastUpdatedAt();
        vm.warp(block.timestamp + 1 days);

        // 100% collapse to zero: deviation = WAD exactly, < 2e18 -> no tick
        source.setValue(0);
        assertEq(clock.poke(), seeded, "collapse to zero must not tick");

        // collapse to 1 wei: floors below WAD -> no tick
        source.setValue(1);
        assertEq(clock.poke(), seeded, "collapse to 1 wei must not tick");

        // +190%: delta/cv = 1.9e18 < 2e18 -> no tick
        source.setValue(2.9e18);
        assertEq(clock.poke(), seeded, "+190% must not tick");

        // exactly 3x: delta/cv = 2e18 >= 2e18 -> ticks
        source.setValue(3e18);
        assertGt(clock.poke(), seeded, "3x up must tick");
    }

    function test_scratch_endToEnd_requestStuckThenAdminRecovers() public {
        _setOracleClock(address(clock));
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        // Realistic price action forever: +/- 50% swings never tick the mis-scaled clock
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 365 days);
        priceFeed.setUpdatedAt(block.timestamp); // keep the kernel's own feed fresh; the clock is over `source`
        source.setValue(1.5e18);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        source.setValue(0.5e18);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        // Even total collapse of the source does not open the gate
        source.setValue(0);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));
        source.setValue(1e18);

        // Recovery path: admin zeroes the clock, in-flight request degrades to pure delay and executes
        _setOracleClock(address(0));
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "admin zeroing the clock must unstick the request");
    }
}
