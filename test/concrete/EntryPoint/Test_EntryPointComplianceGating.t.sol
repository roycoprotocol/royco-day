// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoycoBlacklist } from "../../../src/auth/RoycoBlacklist.sol";
import { ST_LP_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoBlacklist } from "../../../src/interfaces/IRoycoBlacklist.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { toTrancheUnits } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointComplianceGating
 * @notice The entry point on a compliance-enforcing market: with ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER the kernel's
 *         balance-update hook screens every share recipient (escrow-in works because the entry point holds the LP
 *         roles; executions and cancels to non-whitelisted receivers revert), and a wired RoycoBlacklist screens
 *         every party to a share movement
 * @dev The entry point must never weaken tranche gating: it holds the LP roles itself, so these tests pin that the
 *      kernel hook still catches ineligible FINAL recipients even when the entry point is the caller
 */
contract Test_EntryPointComplianceGating is EntryPointTestBase {
    uint256 internal stUnit;

    /// @dev An address holding no LP roles: ineligible to receive shares while the whitelist is enforced
    address internal OUTSIDER;

    function setUp() public {
        MarketParamsConfig memory params = defaultParams();
        params.enforceWhitelistOnTransfer = true;
        _deployMarket(cellA(), params);
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
        OUTSIDER = makeAddr("OUTSIDER");
    }

    // ---------------------------------------------------------------------
    // Whitelist-on-transfer enforcement
    // ---------------------------------------------------------------------

    function test_whitelist_escrowLifecycleWorksForWhitelistedParties() public {
        // Escrow-in (user -> entry point), execution (mint -> receiver), and share escrow for redemptions all pass
        // because the entry point and the users hold the tranche LP roles
        uint256 amount = 10 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);
        _warpPastDepositDelay();
        uint256 shares = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(shares, 0, "the whitelisted lifecycle must work end to end");

        (uint256 redemptionNonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        assertEq(juniorTranche.balanceOf(address(entryPoint)), shares, "the share escrow must pass the whitelist hook");
        _cancelRedemption(USER_A, redemptionNonce, USER_A);
    }

    function test_whitelist_executionMintingToNonWhitelistedReceiverReverts() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, OUTSIDER, 0);
        _warpPastDepositDelay();

        vm.expectRevert(abi.encodeWithSelector(IRoycoDayKernel.ACCOUNT_NOT_WHITELISTED_TRANCHE_LP.selector, OUTSIDER));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(10 * stUnit));

        // The escrow stays cancellable to a whitelisted receiver
        _cancelDeposit(USER_A, nonce, USER_A);
    }

    function test_whitelist_redemptionCancelToNonWhitelistedReceiverReverts() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);

        // Cancelling share escrow to a non-whitelisted receiver is a share transfer and must be screened
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayKernel.ACCOUNT_NOT_WHITELISTED_TRANCHE_LP.selector, OUTSIDER));
        vm.prank(USER_A);
        entryPoint.cancelRedemptionRequest(nonce, OUTSIDER);

        _cancelRedemption(USER_A, nonce, USER_A);
    }

    function test_whitelist_lptRedemptionStSharesLegToNonWhitelistedReceiverReverts() public {
        // Stage an idle premium so LPT redemptions pay a senior-share leg
        setVenueSlippageMode(true);
        applySTPnL(1000);
        _sync();

        uint256 shares = _acquireTrancheShares(USER_A, address(liquidityProviderTranche), 10e18);
        // Revoke the receiver's senior whitelist eligibility AFTER acquiring shares: USER_B keeps JT/LPT roles
        accessManager.revokeRole(ST_LP_ROLE, USER_B);
        (uint256 nonce,) = _requestRedemption(USER_A, address(liquidityProviderTranche), shares, USER_B, 0);
        _warpPastRedemptionDelay();

        // The BPT leg would pass, but the in-kind senior-share leg is an ST share transfer to a non-whitelisted receiver
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayKernel.ACCOUNT_NOT_WHITELISTED_TRANCHE_LP.selector, USER_B));
        vm.prank(USER_A);
        entryPoint.executeRedemption(USER_A, nonce, shares);
    }

    function test_whitelist_revokingEntryPointLpRoleBricksNewEscrows() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        accessManager.revokeRole(ST_LP_ROLE, address(entryPoint));

        // JT escrow still works (JT role intact), but any senior-share movement into the entry point is now screened
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        _cancelRedemption(USER_A, nonce, USER_A);

        uint256 stShares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        vm.startPrank(USER_A);
        seniorTranche.approve(address(entryPoint), stShares);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayKernel.ACCOUNT_NOT_WHITELISTED_TRANCHE_LP.selector, address(entryPoint)));
        entryPoint.requestRedemption(address(seniorTranche), stShares, USER_A, 0, IRoycoDayEntryPoint.RedemptionMode.INKIND);
        vm.stopPrank();
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
