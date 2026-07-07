// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoycoBlacklist } from "../../../src/auth/RoycoBlacklist.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoBlacklist } from "../../../src/interfaces/IRoycoBlacklist.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockRevertingSanctionsList } from "../../mocks/MockRevertingSanctionsList.sol";
import { MockSanctionsList } from "../../mocks/MockSanctionsList.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_BlacklistScreening_RoycoBlacklist
 * @notice Exercises the market blacklist end to end: local list mutation (blacklist, unblacklist, the initial
 *         list at initialization), the Chainalysis sanctions overlay, the enforcement reverts, and the kernel's
 *         screened views once the blacklist is wired into a live market
 * @dev Screening is a compliance hard-stop: a hole here lets a flagged account keep moving tranche shares, and an
 *      over-broad check bricks innocent accounts, so both directions of every predicate are pinned
 */
contract Test_BlacklistScreening_RoycoBlacklist is DayMarketTestBase {
    /// @dev The production blacklist behind a proxy, administered by this test through the market's access manager
    RoycoBlacklist internal roycoBlacklist;

    /// @dev The Chainalysis-shaped sanctions mock the overlay tests flag accounts on
    MockSanctionsList internal sanctionsList;

    /// @dev A flagged account and a clean account reused across the tests
    address internal FLAGGED;
    address internal CLEAN;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        sanctionsList = new MockSanctionsList();
        roycoBlacklist = RoycoBlacklist(
            address(
                new ERC1967Proxy(
                    address(new RoycoBlacklist()), abi.encodeCall(RoycoBlacklist.initialize, (address(accessManager), address(0), new address[](0)))
                )
            )
        );
        FLAGGED = makeAddr("FLAGGED_ACCOUNT");
        CLEAN = makeAddr("CLEAN_ACCOUNT");
    }

    /// @dev Wraps a single account in the calldata array shape the mutation functions take
    function _one(address _account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = _account;
    }

    // =============================
    // Local list mutation
    // =============================

    /// @notice Blacklisting flags the account with its event, and unblacklisting clears it with its event
    function test_BlacklistAccounts_FlagAndClearWithEvents() public {
        vm.expectEmit(address(roycoBlacklist));
        emit IRoycoBlacklist.AccountBlacklisted(FLAGGED);
        roycoBlacklist.blacklistAccounts(_one(FLAGGED));
        assertTrue(roycoBlacklist.isBlacklisted(FLAGGED), "a blacklisted account must read as blacklisted");
        assertFalse(roycoBlacklist.isBlacklisted(CLEAN), "an untouched account must stay clean");

        vm.expectEmit(address(roycoBlacklist));
        emit IRoycoBlacklist.AccountUnblacklisted(FLAGGED);
        roycoBlacklist.unblacklistAccounts(_one(FLAGGED));
        assertFalse(roycoBlacklist.isBlacklisted(FLAGGED), "an unblacklisted account must read clean again");
    }

    /// @notice The null address can be neither blacklisted nor unblacklisted, it is the burn sentinel every mint and burn touches
    function test_RevertIf_NullAddressIsBlacklistedOrUnblacklisted() public {
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        roycoBlacklist.blacklistAccounts(_one(address(0)));
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        roycoBlacklist.unblacklistAccounts(_one(address(0)));
    }

    /// @notice The null address always reads clean, so mints and burns are never screened out
    function test_IsBlacklisted_NullAddressAlwaysClean() public view {
        assertFalse(roycoBlacklist.isBlacklisted(address(0)), "the null address must never read as blacklisted");
    }

    /// @notice Accounts passed at initialization are flagged from genesis
    function test_Initialize_FlagsInitialAccounts() public {
        address[] memory initialAccounts = new address[](2);
        (initialAccounts[0], initialAccounts[1]) = (FLAGGED, CLEAN);
        RoycoBlacklist seeded = RoycoBlacklist(
            address(
                new ERC1967Proxy(address(new RoycoBlacklist()), abi.encodeCall(RoycoBlacklist.initialize, (address(accessManager), address(0), initialAccounts)))
            )
        );
        assertTrue(seeded.isBlacklisted(FLAGGED) && seeded.isBlacklisted(CLEAN), "every genesis-listed account must be flagged");
    }

    /// @notice Initializing with a null authority is rejected, an authority-less blacklist could never be administered
    function test_RevertIf_InitializedWithNullAuthority() public {
        address freshImpl = address(new RoycoBlacklist());
        bytes memory initData = abi.encodeCall(RoycoBlacklist.initialize, (address(0), address(0), new address[](0)));
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ERC1967Proxy(freshImpl, initData);
    }

    // =============================
    // Enforcement
    // =============================

    /// @notice Single and batch enforcement pass for clean accounts and revert naming the exact flagged account
    function test_RevertIf_EnforcedAccountIsBlacklisted() public {
        roycoBlacklist.blacklistAccounts(_one(FLAGGED));

        // The clean single check passes silently
        roycoBlacklist.enforceNotBlacklisted(CLEAN);
        vm.expectRevert(abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, FLAGGED));
        roycoBlacklist.enforceNotBlacklisted(FLAGGED);

        // A batch with the flagged account in the middle reverts on exactly that account
        address[] memory batch = new address[](3);
        (batch[0], batch[1], batch[2]) = (CLEAN, FLAGGED, CLEAN);
        vm.expectRevert(abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, FLAGGED));
        roycoBlacklist.enforceNotBlacklisted(batch);
    }

    // =============================
    // Chainalysis sanctions overlay
    // =============================

    /// @notice A sanctions designation flags an account that was never locally blacklisted, and unwiring the list clears it
    function test_SanctionsOverlay_FlagsWithoutLocalEntryAndUnwiringClears() public {
        vm.expectEmit(address(roycoBlacklist));
        emit IRoycoBlacklist.SanctionsListUpdated(address(sanctionsList));
        roycoBlacklist.setSanctionsList(address(sanctionsList));
        assertEq(roycoBlacklist.getSanctionsList(), address(sanctionsList), "the sanctions list must land in blacklist storage");

        sanctionsList.setSanctioned(FLAGGED, true);
        assertTrue(roycoBlacklist.isBlacklisted(FLAGGED), "a sanctioned account must read as blacklisted with no local entry");
        assertFalse(roycoBlacklist.isBlacklisted(CLEAN), "an unsanctioned account must stay clean");

        // Unwiring the sanctions list (the null address) removes the overlay entirely
        roycoBlacklist.setSanctionsList(address(0));
        assertFalse(roycoBlacklist.isBlacklisted(FLAGGED), "unwiring the sanctions list must clear the overlay flag");
    }

    // =============================
    // Kernel-layer screened views
    // =============================

    /**
     * @notice Once the blacklist is wired into the kernel, every max view reports zero capacity for a flagged account
     * @dev Zeroed max views are the polite front of the hard hook revert: integrators sizing a deposit or redemption
     *      for a flagged account learn it is impossible before building the transaction
     */
    function test_MaxDepositAndMaxRedeem_ZeroForBlacklistedAccount() public {
        // Seed real capacity so the zero reads below are attributable to screening, not an empty market
        // Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1
        _seedMarket(100e18, 30e18);
        vm.prank(MARKET_OPS_ADMIN);
        kernel.setRoycoBlacklist(address(roycoBlacklist));
        roycoBlacklist.blacklistAccounts(_one(FLAGGED));

        assertEq(toUint256(seniorTranche.maxDeposit(FLAGGED)), 0, "senior deposit capacity must be zero for a flagged account");
        assertEq(toUint256(juniorTranche.maxDeposit(FLAGGED)), 0, "junior deposit capacity must be zero for a flagged account");
        assertEq(toUint256(liquidityTranche.maxDeposit(FLAGGED)), 0, "liquidity deposit capacity must be zero for a flagged account");
        assertEq(seniorTranche.maxRedeem(FLAGGED), 0, "senior redemption capacity must be zero for a flagged account");
        assertEq(juniorTranche.maxRedeem(FLAGGED), 0, "junior redemption capacity must be zero for a flagged account");
        assertEq(liquidityTranche.maxRedeem(FLAGGED), 0, "liquidity redemption capacity must be zero for a flagged account");

        // The same views stay live for a clean account: the senior provider still holds its 100e18 seeded shares
        assertEq(seniorTranche.maxRedeem(ST_PROVIDER), 100e18, "a clean account's redemption capacity must be unaffected by screening");
    }

    // =============================
    // Blacklist bypass attempts (adversarial)
    // =============================

    /**
     * @notice A flagged holder cannot move tranche shares out on ANY path: direct transfer, a pre-arranged
     *         delegate transferFrom, or an inbound transfer parking value on the flagged account all revert
     * @dev The attacker's playbook after being flagged is to route around the screen through an ally: the
     *      kernel's preTrancheBalanceUpdateHook screens caller, from, and to on every balance update, so the
     *      allowance path and the receive path are as dead as the direct one. Every attempt must leave
     *      balances byte-identical
     */
    function test_RevertIf_BlacklistedAccountMovesSharesViaTransferOrTransferFrom() public {
        _seedMarket(100e18, 30e18);
        // Park shares on the soon-to-be-flagged account and pre-approve the ally BEFORE the flag lands
        address ally = makeAddr("BLACKLIST_ALLY");
        vm.prank(ST_PROVIDER);
        seniorTranche.transfer(FLAGGED, 10e18);
        vm.prank(FLAGGED);
        seniorTranche.approve(ally, 10e18);

        vm.prank(MARKET_OPS_ADMIN);
        kernel.setRoycoBlacklist(address(roycoBlacklist));
        roycoBlacklist.blacklistAccounts(_one(FLAGGED));

        // 1. Direct transfer out by the flagged holder
        vm.prank(FLAGGED);
        vm.expectRevert(abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, FLAGGED));
        seniorTranche.transfer(ally, 1e18);

        // 2. The ally spends the pre-flag allowance: the hook screens `from`, so the escape hatch is closed
        vm.prank(ally);
        vm.expectRevert(abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, FLAGGED));
        seniorTranche.transferFrom(FLAGGED, ally, 1e18);

        // 3. A clean holder cannot park more value ON the flagged account (the hook screens `to`)
        vm.prank(ST_PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, FLAGGED));
        seniorTranche.transfer(FLAGGED, 1e18);

        // Every balance is untouched by the three failed attempts
        assertEq(seniorTranche.balanceOf(FLAGGED), 10e18, "the flagged balance must be frozen in place");
        assertEq(seniorTranche.balanceOf(ally), 0, "the ally must have extracted nothing");
        assertEq(seniorTranche.balanceOf(ST_PROVIDER), 90e18, "the clean holder's balance must be unchanged");
        assertEq(seniorTranche.allowance(FLAGGED, ally), 10e18, "the failed transferFrom must not have consumed allowance");
    }

    // =============================
    // Sanctions list failure modes and recovery
    // =============================

    /**
     * @notice A codeless address wired as the sanctions list bricks every screen on the blacklist itself
     * @dev Every account that is not locally flagged (which is every account here) falls through to the
     *      sanctions overlay, so the overlay call sits on the hot path of every screen. A high-level call
     *      that expects return data from an address with no code reverts at the EVM level with empty revert
     *      data, so a codeless list turns every clean-account query into a bare revert
     */
    function test_RevertIf_SanctionsListHasNoCode_EveryScreenBricks() public {
        // The setter performs no probe, so the codeless target lands in storage without complaint
        roycoBlacklist.setSanctionsList(makeAddr("CODELESS_SANCTIONS_LIST"));

        // The membership query dies inside the codeless overlay call (empty revert data, hence the bare expect)
        vm.expectRevert();
        roycoBlacklist.isBlacklisted(CLEAN);

        // Both enforcement overloads route through the same query, so they die identically
        vm.expectRevert();
        roycoBlacklist.enforceNotBlacklisted(CLEAN);
        vm.expectRevert();
        roycoBlacklist.enforceNotBlacklisted(_one(CLEAN));
    }

    /**
     * @notice A reverting sanctions list bricks every guarded market flow AND the max views once wired into the kernel
     * @dev Every tranche share balance update (transfer, deposit mint, redemption burn) routes through the
     *      kernel's pre-balance-update hook, which batch-screens caller, from, and to, so one broken sanctions
     *      oracle takes the whole market hostage. The max views are meant to be the polite integrator surface
     *      that reports zero capacity instead of reverting, yet they consult the same blacklist first, so the
     *      oracle failure breaches even the never-revert view contract
     */
    function test_RevertIf_SanctionsListReverts_AllGuardedMarketFlowsBrick() public {
        // Seed real balances first so every attempt below would succeed absent the broken oracle
        // Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1
        _seedMarket(100e18, 30e18);
        vm.prank(MARKET_OPS_ADMIN);
        kernel.setRoycoBlacklist(address(roycoBlacklist));
        roycoBlacklist.setSanctionsList(address(new MockRevertingSanctionsList()));

        // 1. Transfers: the hook screens the caller before anything else, and that screen dies in the oracle
        vm.prank(ST_PROVIDER);
        vm.expectRevert(MockRevertingSanctionsList.SANCTIONS_LIST_UNAVAILABLE.selector);
        seniorTranche.transfer(CLEAN, 1e18);

        // 2. Deposits: the mint's balance update routes through the same hook, so new capital cannot enter
        stJtVault.mintShares(JT_PROVIDER, 10e18);
        vm.startPrank(JT_PROVIDER);
        stJtVault.approve(address(juniorTranche), 10e18);
        vm.expectRevert(MockRevertingSanctionsList.SANCTIONS_LIST_UNAVAILABLE.selector);
        juniorTranche.deposit(toTrancheUnits(10e18), JT_PROVIDER);
        vm.stopPrank();

        // 3. Redemptions: the burn's balance update routes through the hook, so existing capital cannot leave
        vm.prank(ST_PROVIDER);
        vm.expectRevert(MockRevertingSanctionsList.SANCTIONS_LIST_UNAVAILABLE.selector);
        seniorTranche.redeem(1e18, ST_PROVIDER, ST_PROVIDER);

        // 4. Every max view checks the blacklist before anything else, so instead of reporting zero capacity
        //    (their contract for a blocked account) they all revert with the oracle's error
        vm.expectRevert(MockRevertingSanctionsList.SANCTIONS_LIST_UNAVAILABLE.selector);
        seniorTranche.maxDeposit(CLEAN);
        vm.expectRevert(MockRevertingSanctionsList.SANCTIONS_LIST_UNAVAILABLE.selector);
        juniorTranche.maxDeposit(CLEAN);
        vm.expectRevert(MockRevertingSanctionsList.SANCTIONS_LIST_UNAVAILABLE.selector);
        liquidityTranche.maxDeposit(CLEAN);
        vm.expectRevert(MockRevertingSanctionsList.SANCTIONS_LIST_UNAVAILABLE.selector);
        seniorTranche.maxRedeem(ST_PROVIDER);
        vm.expectRevert(MockRevertingSanctionsList.SANCTIONS_LIST_UNAVAILABLE.selector);
        juniorTranche.maxRedeem(JT_PROVIDER);
        vm.expectRevert(MockRevertingSanctionsList.SANCTIONS_LIST_UNAVAILABLE.selector);
        liquidityTranche.maxRedeem(LT_PROVIDER);
    }

    /**
     * @notice Unwiring the sanctions list (the null address) recovers a market bricked by a broken list
     * @dev The recovery lever must itself be immune to the failure it recovers from: setSanctionsList never
     *      consults the outgoing list, it only overwrites storage, so governance can always swap a broken
     *      oracle for nothing and restore every guarded flow in one call
     */
    function test_SetSanctionsList_NullAddressRecoversBrickedMarket() public {
        // Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1
        _seedMarket(100e18, 30e18);
        vm.prank(MARKET_OPS_ADMIN);
        kernel.setRoycoBlacklist(address(roycoBlacklist));
        roycoBlacklist.setSanctionsList(address(new MockRevertingSanctionsList()));

        // The market is bricked: a routine transfer between two clean accounts dies in the broken oracle
        vm.prank(ST_PROVIDER);
        vm.expectRevert(MockRevertingSanctionsList.SANCTIONS_LIST_UNAVAILABLE.selector);
        seniorTranche.transfer(CLEAN, 5e18);

        // Governance unwires the broken list, the setter succeeds because it never queries the outgoing list
        vm.expectEmit(address(roycoBlacklist));
        emit IRoycoBlacklist.SanctionsListUpdated(address(0));
        roycoBlacklist.setSanctionsList(address(0));

        // The previously-reverting transfer now lands: 5e18 of the seeded 100e18 senior shares move
        vm.prank(ST_PROVIDER);
        seniorTranche.transfer(CLEAN, 5e18);
        assertEq(seniorTranche.balanceOf(ST_PROVIDER), 95e18, "the sender must hold the seeded balance minus the transfer");
        assertEq(seniorTranche.balanceOf(CLEAN), 5e18, "the receiver must hold exactly the transferred shares");

        // The previously-bricked deposit path also lands: 10e18 vault shares into a junior tranche holding
        // 30e18 shares against 30e18 effective NAV mint 10e18 x 30 / 30 = 10e18 new shares
        stJtVault.mintShares(JT_PROVIDER, 10e18);
        vm.startPrank(JT_PROVIDER);
        stJtVault.approve(address(juniorTranche), 10e18);
        juniorTranche.deposit(toTrancheUnits(10e18), JT_PROVIDER);
        vm.stopPrank();
        assertEq(juniorTranche.balanceOf(JT_PROVIDER), 40e18, "the junior provider must hold the seeded 30e18 plus the 10e18 minted");
    }

    /**
     * @notice The sanctions list setter accepts any nonzero address without probing that it can answer isSanctioned
     * @dev Divergence pin: setSanctionsList only overwrites storage, so a codeless (or otherwise broken) target
     *      is accepted at configuration time and every screen, every guarded market flow, and every max view
     *      reverts from that moment until governance unwires it. Expected behavior: the setter probes the target
     *      with an isSanctioned call so an unresponsive list is rejected before it can take the market down
     */
    function test_FINDING_32_SetSanctionsList_AcceptsTargetThatCannotAnswerIsSanctioned() public {
        // Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1
        _seedMarket(100e18, 30e18);
        vm.prank(MARKET_OPS_ADMIN);
        kernel.setRoycoBlacklist(address(roycoBlacklist));

        // The codeless target sails through the setter: event emitted, storage written, no probe performed
        address codeless = makeAddr("UNRESPONSIVE_SANCTIONS_LIST");
        vm.expectEmit(address(roycoBlacklist));
        emit IRoycoBlacklist.SanctionsListUpdated(codeless);
        roycoBlacklist.setSanctionsList(codeless);
        assertEq(roycoBlacklist.getSanctionsList(), codeless, "the unprobed codeless target must have landed in storage");

        // One configuration mistake later, a routine transfer between two clean accounts is dead
        // (the codeless overlay call reverts with empty data, hence the bare expects)
        vm.prank(ST_PROVIDER);
        vm.expectRevert();
        seniorTranche.transfer(CLEAN, 1e18);

        // and the never-revert view surface reverts instead of reporting capacity
        vm.expectRevert();
        seniorTranche.maxDeposit(CLEAN);
    }
}
