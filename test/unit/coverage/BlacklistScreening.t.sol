// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoycoBlacklist } from "../../../src/auth/RoycoBlacklist.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoBlacklist } from "../../../src/interfaces/IRoycoBlacklist.sol";
import { ISanctionsList } from "../../../src/interfaces/external/chainalysis/ISanctionsList.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../base/fixtures/MarketParams.sol";
import { cellA } from "../../base/fixtures/TokenConfigs.sol";
import { TrancheFixture } from "../../base/fixtures/TrancheFixture.sol";

/// @notice Minimal Chainalysis-shaped sanctions list with a settable designation per address
contract SanctionsListStub is ISanctionsList {
    /// @dev The sanctions designations this stub reports
    mapping(address account => bool sanctioned) private _sanctioned;

    /// @notice Flags or clears an address's sanctions designation
    function setSanctioned(address _account, bool _isSanctioned) external {
        _sanctioned[_account] = _isSanctioned;
    }

    /// @inheritdoc ISanctionsList
    function isSanctioned(address _account) external view override(ISanctionsList) returns (bool) {
        return _sanctioned[_account];
    }
}

/**
 * @title BlacklistScreeningTest
 * @notice Exercises the market blacklist end to end: local list mutation (blacklist, unblacklist, the initial
 *         list at initialization), the Chainalysis sanctions overlay, the enforcement reverts, and the kernel's
 *         screened views once the blacklist is wired into a live market
 * @dev Screening is a compliance hard-stop: a hole here lets a flagged account keep moving tranche shares, and an
 *      over-broad check bricks innocent accounts, so both directions of every predicate are pinned
 */
contract BlacklistScreeningTest is TrancheFixture {
    /// @dev The production blacklist behind a proxy, administered by this test through the market's access manager
    RoycoBlacklist internal roycoBlacklist;

    /// @dev The Chainalysis-shaped sanctions stub the overlay tests flag accounts on
    SanctionsListStub internal sanctionsList;

    /// @dev A flagged account and a clean account reused across the tests
    address internal FLAGGED;
    address internal CLEAN;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        sanctionsList = new SanctionsListStub();
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
    function test_BlacklistAndUnblacklist_flagAndClearWithEvents() public {
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
    function test_IsBlacklisted_nullAddressAlwaysClean() public view {
        assertFalse(roycoBlacklist.isBlacklisted(address(0)), "the null address must never read as blacklisted");
    }

    /// @notice Accounts passed at initialization are flagged from genesis
    function test_Initialize_flagsInitialAccounts() public {
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
    function test_EnforceNotBlacklisted_revertsNamingTheFlaggedAccount() public {
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
    function test_SanctionsOverlay_flagsWithoutLocalEntryAndUnwiringClears() public {
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
    function test_KernelMaxViews_zeroForBlacklistedAccount() public {
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
}
