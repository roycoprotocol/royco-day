// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { defaultParams } from "../utils/MarketParams.sol";
import { cellG } from "../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../utils/DayMarketTestBase.sol";
import { MockERC20C } from "../mocks/MockERC20C.sol";

/**
 * @title Test_MarketLifecycle_FeeOnTransferUnderlying_NonStandardTokens
 * @notice EXPECTED-FAILURE shape: a fee-on-transfer ST/JT vault underlying (10bps burned in transit) breaks the
 *         vault's balance-vs-accounting identity on the very first deposit, so the full lifecycle suite is
 *         deliberately NOT instantiated for this shape — this dedicated test pins the exact broken invariant and
 *         the exact revert instead, documenting why fee-on-transfer tokens are excluded by policy
 * @dev Nothing in the deployment path rejects the token (the exclusion is policy, not code): the market deploys
 *      cleanly and the poison sits dormant until real underlying moves. The market itself custodies the 4626
 *      SHARE, so its NAV marks inherit the vault's phantom pre-fee accounting one level down
 * @dev Nightly-only concrete, matched by the shared NonStandardTokens contract-name suffix
 *      (forge test --match-contract NonStandardTokens)
 */
contract Test_MarketLifecycle_FeeOnTransferUnderlying_NonStandardTokens is DayMarketTestBase {
    function setUp() public {
        _deployMarket(cellG(), defaultParams());
    }

    /**
     * @notice A deposit through the fee-on-transfer underlying books pre-fee assets the vault never received, and
     *         the shortfall reverts the final redemption
     * @dev Builds the smallest honest scenario: one depositor moves 100 whole underlying into the ST/JT vault,
     *      the 10bps transit fee burns 100e18 x 10 / 10_000 = 0.1e18 in flight, and the vault mints shares
     *      against the full pre-fee amount. Why it matters: the vault's booked assets now exceed its holdings by
     *      exactly the fee, so every NAV mark built on convertToAssets overstates realizable value and the last
     *      holder out cannot be paid — the exact insolvency mechanism the policy exclusion exists to prevent
     */
    function test_FeeOnTransferUnderlying_depositBooksPhantomAssetsAndFinalRedeemReverts() public {
        address depositor = makeAddr("FEE_ON_TRANSFER_DEPOSITOR");
        // mint() credits balances directly with no transfer, so the full 100e18 arrives fee-free
        stJtUnderlying.mint(depositor, 100e18);

        vm.startPrank(depositor);
        stJtUnderlying.approve(address(stJtVault), 100e18);
        uint256 shares = stJtVault.deposit(100e18, depositor);
        vm.stopPrank();

        // The vault mints against the PRE-FEE amount: convertToShares(100e18) at rate 1.0 = 100e18 shares
        assertEq(shares, 100e18, "the vault mints shares against the pre-fee deposit amount");
        // But only 100e18 - 100e18 x 10 / 10_000 = 99.9e18 underlying actually arrived
        assertEq(stJtUnderlying.balanceOf(address(stJtVault)), 99.9e18, "10bps of the deposit burned in transit");
        // Broken invariant: booked assets exceed real holdings by exactly the 0.1e18 transit fee
        assertEq(stJtVault.totalAssets(), 100e18, "totalAssets books the phantom pre-fee amount");
        assertEq(stJtVault.totalAssets() - stJtUnderlying.balanceOf(address(stJtVault)), 0.1e18, "the vault's insolvency equals the 10bps transit fee exactly");

        // The shortfall lands on the last holder out: a full redemption owes convertToAssets(100e18) = 100e18
        // underlying from a 99.9e18 balance, so the payout transfer must revert
        vm.prank(depositor);
        vm.expectRevert(MockERC20C.INSUFFICIENT_BALANCE.selector);
        stJtVault.redeem(100e18, depositor, depositor);
    }
}
