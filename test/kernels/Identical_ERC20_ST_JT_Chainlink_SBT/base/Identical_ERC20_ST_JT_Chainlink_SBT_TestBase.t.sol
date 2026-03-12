// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
    Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel
} from "../../../../src/kernels/Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel.sol";
import { YieldBearingERC20Chainlink_TestBase } from "../../Identical_ERC20_ST_JT_Chainlink/base/YieldBearingERC20Chainlink_TestBase.t.sol";

/// @title Identical_ERC20_ST_JT_Chainlink_SBT_TestBase
/// @notice Base test for SoulBoundTrancheShares kernel — verifies shares cannot be P2P transferred but can be seized
abstract contract Identical_ERC20_ST_JT_Chainlink_SBT_TestBase is YieldBearingERC20Chainlink_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _grantLPRoles(address _who) internal {
        vm.startPrank(LP_ROLE_ADMIN_ADDRESS);
        FACTORY.grantRole(ST_LP_ROLE, _who, 0);
        FACTORY.grantRole(JT_LP_ROLE, _who, 0);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SOUL-BOUND: P2P TRANSFERS BLOCKED
    // ═══════════════════════════════════════════════════════════════════════════

    function test_soulBound_ST_transferReverts() external {
        uint256 depositAmount = _minDepositAmount() * 10;
        _depositJT(ALICE_ADDRESS, depositAmount);
        uint256 stShares = _depositST(BOB_ADDRESS, depositAmount / 2);

        // Grant receiver ST LP role so the LP whitelist check passes and the soul-bound check is hit
        _grantLPRoles(ALICE_ADDRESS);

        vm.prank(BOB_ADDRESS);
        vm.expectRevert(Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel.TRANCHE_SHARES_ARE_SOUL_BOUND.selector);
        IERC20(address(ST)).transfer(ALICE_ADDRESS, stShares);
    }

    function test_soulBound_JT_transferReverts() external {
        uint256 depositAmount = _minDepositAmount() * 10;
        uint256 jtShares = _depositJT(ALICE_ADDRESS, depositAmount);

        // Grant receiver JT LP role so the LP whitelist check passes and the soul-bound check is hit
        _grantLPRoles(BOB_ADDRESS);

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel.TRANCHE_SHARES_ARE_SOUL_BOUND.selector);
        IERC20(address(JT)).transfer(BOB_ADDRESS, jtShares);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SOUL-BOUND: SEIZE BYPASSES TRANSFER RESTRICTION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_soulBound_seizeShares_ST_succeeds() external {
        uint256 depositAmount = _minDepositAmount() * 10;
        _depositJT(ALICE_ADDRESS, depositAmount);
        uint256 stShares = _depositST(BOB_ADDRESS, depositAmount / 2);

        vm.prank(TRANSFER_AGENT_ADDRESS);
        ST.seizeShares(BOB_ADDRESS, ALICE_ADDRESS, stShares);

        assertEq(IERC20(address(ST)).balanceOf(ALICE_ADDRESS), stShares, "Receiver should have seized ST shares");
        assertEq(IERC20(address(ST)).balanceOf(BOB_ADDRESS), 0, "Source should have no ST shares");
    }

    function test_soulBound_seizeShares_JT_succeeds() external {
        uint256 depositAmount = _minDepositAmount() * 10;
        uint256 jtShares = _depositJT(ALICE_ADDRESS, depositAmount);

        vm.prank(TRANSFER_AGENT_ADDRESS);
        JT.seizeShares(ALICE_ADDRESS, BOB_ADDRESS, jtShares);

        assertEq(IERC20(address(JT)).balanceOf(BOB_ADDRESS), jtShares, "Receiver should have seized JT shares");
        assertEq(IERC20(address(JT)).balanceOf(ALICE_ADDRESS), 0, "Source should have no JT shares");
    }

    function test_soulBound_seizeAndRedeemShares_ST_succeeds() external {
        uint256 depositAmount = _minDepositAmount() * 10;
        _depositJT(ALICE_ADDRESS, depositAmount);
        uint256 stShares = _depositST(BOB_ADDRESS, depositAmount / 2);

        vm.prank(TRANSFER_AGENT_ADDRESS);
        ST.seizeAndRedeemShares(BOB_ADDRESS, TRANSFER_AGENT_ADDRESS, stShares);

        assertEq(IERC20(address(ST)).balanceOf(BOB_ADDRESS), 0, "Source should have no ST shares after seizure");
    }

    function test_soulBound_seizeAndRedeemShares_JT_succeeds() external {
        uint256 depositAmount = _minDepositAmount() * 10;
        uint256 jtShares = _depositJT(ALICE_ADDRESS, depositAmount);

        vm.prank(TRANSFER_AGENT_ADDRESS);
        JT.seizeAndRedeemShares(ALICE_ADDRESS, TRANSFER_AGENT_ADDRESS, jtShares);

        assertEq(IERC20(address(JT)).balanceOf(ALICE_ADDRESS), 0, "Source should have no JT shares after seizure");
    }
}
