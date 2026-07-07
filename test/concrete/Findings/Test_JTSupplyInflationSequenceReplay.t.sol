// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { DayMarketHandler } from "../../invariant/handlers/DayMarketHandler.sol";

/**
 * @notice Byte-exact replay of the recorded 33-op invariant sequence that historically bricked
 *         `syncTrancheAccounting`: repeated forced-liquidation losses wiped the junior effective NAV to dust,
 *         successive junior deposits against that dust NAV inflated the junior share supply toward 1e77, and the
 *         next sync's junior protocol-fee share mint (supply / 9 at a 10% fee) overflowed uint256 inside the
 *         ERC20 supply update, reverting every future sync on a healthy market.
 * @dev Fixed by the mint-dilution clamp in ValuationLogic (any single mint may own at most 1 - epsilon of the
 *      post-mint supply), which bounds supply growth per deposit and keeps the fee mint representable. This test
 *      pins the fix by replaying the exact recorded handler calldata: every step must execute without tripping a
 *      handler-observed violation. The residual supply-inflation cliff itself stays pinned separately by
 *      test_FINDING_11 in Test_SpecDivergences.
 */
contract Test_JTSupplyInflationSequenceReplay_Findings is Test {
    struct Step {
        bytes data;
        string name;
    }

    Step[] internal steps;
    DayMarketHandler internal handler;

    function setUp() public {
        handler = new DayMarketHandler(false);
        handler.init();
        steps.push(Step(hex"0780321c", "aimed_loseUntilLiquidation"));
        steps.push(Step(hex"385aaf6c000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000cbb", "op_jtDeposit"));
        steps.push(Step(hex"0780321c", "aimed_loseUntilLiquidation"));
        steps.push(Step(hex"385aaf6c0000000000000000000000000000000000000000000000000001f0edc314edba000000000000000000000000000169778c3f07cd5c3b7d655b919a7e1ddcd784", "op_jtDeposit"));
        steps.push(Step(hex"0780321c", "aimed_loseUntilLiquidation"));
        steps.push(Step(hex"3e1719860000295a458841f0b05b68cd201852f8ff1dc5e6dbc3ee1908fca7bcce79d5a1000000000000000000000000000000000000000000a9ce1063d76433828602cf", "op_adminParamNudge"));
        steps.push(Step(hex"385aaf6c0000000000000000000000000426e5cd6a26499ccba76276f96856a05e64f127000000000000000000000000000000000000000016a89dafe05fff4afa4e1200", "op_jtDeposit"));
        steps.push(Step(hex"0780321c", "aimed_loseUntilLiquidation"));
        steps.push(Step(hex"934ba8da00000000000000000000000000000da35b72796aaf8a2a69c5d4eb7f5491cb31", "aimed_coveredDrawdown"));
        steps.push(Step(hex"f8d715fefffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed4", "op_stPnL"));
        steps.push(Step(hex"385aaf6c00000000000000000000261179f780d3eaed2884ab89595ded0aa7fb0fcc400900000000000000000000000000000000000000000000000000000000000040e7", "op_jtDeposit"));
        steps.push(Step(hex"0780321c", "aimed_loseUntilLiquidation"));
        steps.push(Step(hex"385aaf6c00000000000000000000000000000000000000000000000002c68af0bb14000000000000000000000000000000000000000000000000000000000000000025d5", "op_jtDeposit"));
        steps.push(Step(hex"0780321c", "aimed_loseUntilLiquidation"));
        steps.push(Step(hex"385aaf6c00000000000000000000000000000000000000000000000000000000000029490000000000000000000000000000000000000000000000000000000000007280", "op_jtDeposit"));
        steps.push(Step(hex"0780321c", "aimed_loseUntilLiquidation"));
        steps.push(Step(hex"3e17198600000000000000000dcafe8ce057b4e6bd86a1bfa7d95fa5ef879c879723600500000000000000000000000000000000000823565736c135c242320f41954eee", "op_adminParamNudge"));
        steps.push(Step(hex"f8d715fefffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed4", "op_stPnL"));
        steps.push(Step(hex"385aaf6c00000000000000000000000000000000000000000000000000000000000020a200000000000000000000000000000000000000000000000000000000000059da", "op_jtDeposit"));
        steps.push(Step(hex"385aaf6c00000190a652e0e2a4aeebec2010eac33cc15a25e2ffc27d88018ffb10df9b5c000000000000000068930a511bd505cca955955dc1f0f2bfb7a990e0af412fdc", "op_jtDeposit"));
        steps.push(Step(hex"385aaf6c00000000000000000000000000000000000023a4971a34121e0faf834eabf686000000000000000000059ff502af07c0d915e44e9c5d6b123c3e195146b17d7b", "op_jtDeposit"));
        steps.push(Step(hex"0780321c", "aimed_loseUntilLiquidation"));
        steps.push(Step(hex"385aaf6c00000000000000000000000000000000000000000000000000284a6bd2fb38320000000000000000000000000000013e9cf9386853512483fd0c5d6181518150", "op_jtDeposit"));
        steps.push(Step(hex"0780321c", "aimed_loseUntilLiquidation"));
        steps.push(Step(hex"934ba8da000000000000000000000000000000000000000000000000000000644f0398b9", "aimed_coveredDrawdown"));
        steps.push(Step(hex"385aaf6c000000000000000000000000000000000000000000000000000000000000ed000000000000000000000000000000000000000000000000000000000000002d2e", "op_jtDeposit"));
        steps.push(Step(hex"0780321c", "aimed_loseUntilLiquidation"));
        steps.push(Step(hex"385aaf6c00000000000000000000000000f52c11bf224eed3f30e8aa443c382bc4b93dcf000000000000000000007fabc4107dc79181684b9d7b41868b8f37b7ac399c31", "op_jtDeposit"));
        steps.push(Step(hex"0780321c", "aimed_loseUntilLiquidation"));
        steps.push(Step(hex"934ba8da00000000000000000000000000000000000000000000000000470de4df820000", "aimed_coveredDrawdown"));
        steps.push(Step(hex"f8d715fe000000000000000000000000000000000000000000000000000000012be31bd2", "op_stPnL"));
        steps.push(Step(hex"f8d715fefffffffffffffffffa2610b0f740ff12ebc4d1494fcf1d437d0ae212b849f430", "op_stPnL"));
        steps.push(Step(hex"f8d715fefffffffe95ed463fbf644bd2878a5d11c59b62047c4e321fef89847c5ef59ef8", "op_stPnL"));
    }

    /// @notice Replays the recorded sequence step by step; the mint-dilution clamp must keep every sync alive
    /// @dev A regression here means supply inflation can again push a protocol-fee share mint past uint256
    function test_FINDING_11_replayedLiquidationSequenceCannotBrickSync() public {
        for (uint256 i; i < steps.length; ++i) {
            (bool ok,) = address(handler).call(steps[i].data);
            ok; // a handler op may legitimately no-op; the property is the violation counter staying at zero
        }
        assertEq(handler.ghost_violationCount(), 0, handler.ghost_violation());
    }
}
