// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoycoBlacklist } from "../../../src/auth/RoycoBlacklist.sol";
import { IRoycoBlacklist } from "../../../src/interfaces/IRoycoBlacklist.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { toTrancheUnits } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointComplianceGating
 * @notice The entry point on a market with a wired RoycoBlacklist: the kernel's balance-update hook screens every
 *         party to a share movement, so a flagged sender cannot escrow shares and a flagged receiver cannot take
 *         delivery of execution proceeds
 * @dev The entry point must never weaken tranche gating: it moves shares on its users' behalf, so these tests pin
 *      that the kernel hook still catches ineligible parties even when the entry point is the caller
 */
contract Test_EntryPointComplianceGating is EntryPointTestBase {
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
    }

    // ---------------------------------------------------------------------
    // Blacklist screening
    // ---------------------------------------------------------------------

    /// @dev Deploys the production blacklist, wires it into the kernel, and flags the specified account
    function _wireBlacklistAndFlag(address _account) internal {
        RoycoBlacklist blacklist = RoycoBlacklist(
            address(
                new ERC1967Proxy(
                    address(new RoycoBlacklist()), abi.encodeCall(RoycoBlacklist.initialize, (address(accessManager), address(0), new address[](0)))
                )
            )
        );
        vm.prank(MARKET_OPS_ADMIN);
        kernel.setRoycoBlacklist(address(blacklist));
        address[] memory accounts = new address[](1);
        accounts[0] = _account;
        blacklist.blacklistAccounts(accounts);
    }

    function test_blacklist_flaggedUserCannotEscrowShares() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        _wireBlacklistAndFlag(USER_A);

        // The share escrow transfer screens `from`, so a flagged user cannot register a redemption request
        vm.startPrank(USER_A);
        juniorTranche.approve(address(entryPoint), shares);
        vm.expectRevert(abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, USER_A));
        entryPoint.requestRedemption(address(juniorTranche), shares, USER_A, 0, IRoycoDayEntryPoint.RedemptionMode.INKIND);
        vm.stopPrank();
    }

    function test_blacklist_flaggedReceiverCannotReceiveExecutionProceeds() public {
        // Deposit escrow-in is an ASSET transfer (not screened), so the request lands; the mint at execution is screened
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_B, 0);
        _wireBlacklistAndFlag(USER_B);
        _warpPastDepositDelay();

        vm.expectRevert(abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, USER_B));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(10 * stUnit));

        // The escrowed assets remain recoverable to the (clean) request owner
        _cancelDeposit(USER_A, nonce, USER_A);
    }
}
