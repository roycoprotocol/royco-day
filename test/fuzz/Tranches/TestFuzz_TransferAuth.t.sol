// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoBlacklist } from "../../../src/auth/RoycoBlacklist.sol";
import { IRoycoBlacklist } from "../../../src/interfaces/IRoycoBlacklist.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title TestFuzz_TransferAuth_Tranches
 * @notice Fuzzes every caller/sender/receiver share-transfer authorization combination on all three
 *         tranches: every transfer routes through the kernel's pre-balance-update hook, which screens the
 *         caller, sender, and receiver against the market's blacklist
 * @dev The expected outcome is re-derived independently from the fuzzed configuration (who was blacklisted)
 *      and asserted in both directions: a predicted revert must revert with exactly the predicted error and
 *      account, and a predicted success must move exactly the transferred balance
 * @dev Holding a tranche LP role gates `deposit`/`redeem` on the tranche itself, not share receipt, so shares
 *      transfer freely to any non-blacklisted address regardless of the receiver's roles
 */
contract TestFuzz_TransferAuth_Tranches is DayMarketTestBase {
    /// @dev Actor pool size: small enough that from/to/caller alias each other regularly, exercising every overlap
    uint256 internal constant ACTOR_POOL_SIZE = 4;

    /// @notice Returns the pool actor at the given index, fresh addresses disjoint from every fixture role wallet
    function _actor(uint256 _index) internal returns (address actor) {
        actor = makeAddr(string.concat("TRANSFER_ACTOR_", vm.toString(_index)));
    }

    /**
     * @notice Seeds the market and hands `_from` a positive share balance of the chosen tranche through
     *         production paths only (tranche deposits by the providers, then a plain provider transfer)
     * @dev The seeding transfer itself passes the hook: no blacklist is configured yet, and share receipt is
     *      unconditional. The LPT balance comes from the fixture's auto-seeded quote-only depth backing the
     *      senior deposit (5% of 100e18 plus cushion)
     */
    function _seedActorWithShares(uint256 _trancheIdx, address _from) internal {
        // Coverage after seeding: (100e18 + 50e18) * 0.2 / 50e18 = 0.6 <= 1, so both deposits clear their gates
        _seedMarket(100e18, 50e18);
        if (_trancheIdx == 0) {
            uint256 stHalf = seniorTranche.balanceOf(ST_PROVIDER) / 2;
            vm.prank(ST_PROVIDER);
            seniorTranche.transfer(_from, stHalf);
        } else if (_trancheIdx == 1) {
            uint256 jtHalf = juniorTranche.balanceOf(JT_PROVIDER) / 2;
            vm.prank(JT_PROVIDER);
            juniorTranche.transfer(_from, jtHalf);
        } else {
            uint256 lptHalf = liquidityProviderTranche.balanceOf(LPT_PROVIDER) / 2;
            vm.prank(LPT_PROVIDER);
            liquidityProviderTranche.transfer(_from, lptHalf);
        }
    }

    /// @notice Deploys the production blacklist behind a proxy, wires it into the kernel, and blacklists one account per set flag
    function _configureBlacklist(bool _flagCaller, bool _flagFrom, bool _flagTo, address _caller, address _from, address _to) internal {
        RoycoBlacklist blacklist = new RoycoBlacklist(address(this), address(0), new address[](0));
        vm.prank(MARKET_OPS_ADMIN);
        kernel.setRoycoBlacklist(address(blacklist));

        // Blacklisting is idempotent, so aliased actors flagged through several roles are simply re-flagged
        if (_flagCaller) _blacklistOne(blacklist, _caller);
        if (_flagFrom) _blacklistOne(blacklist, _from);
        if (_flagTo) _blacklistOne(blacklist, _to);
    }

    /// @notice Blacklists a single account (the test contract administers the market's access manager)
    function _blacklistOne(RoycoBlacklist _blacklist, address _account) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = _account;
        _blacklist.blacklistAccounts(accounts);
    }

    /**
     * Property: a tranche share transfer succeeds if and only if no involved party is blacklisted. The
     * production hook screens in a fixed order — caller, then sender, then receiver — so the expected error
     * and its offending account are re-derived here from the fuzzed flags alone (union of the flags per
     * address, since aliased actors share one blacklist entry) and matched exactly. On the success leg the
     * balances must move by exactly the transferred amount
     */
    function testFuzz_TrancheTransfer_AuthorizedExactlyWhenNoPartyBlacklisted(
        uint256 _trancheIdx,
        uint256 _fromIdx,
        uint256 _toIdx,
        uint256 _callerIdx,
        bool _blacklistConfigured,
        bool _flagCaller,
        bool _flagFrom,
        bool _flagTo,
        uint256 _amount
    )
        public
    {
        uint256 trancheIdx = bound(_trancheIdx, 0, 2); // uniform over senior / junior / liquidity
        address from = _actor(bound(_fromIdx, 0, ACTOR_POOL_SIZE - 1)); // 4-actor pool, so roles alias often
        address to = _actor(bound(_toIdx, 0, ACTOR_POOL_SIZE - 1)); // same pool as the sender
        address caller = _actor(bound(_callerIdx, 0, ACTOR_POOL_SIZE - 1)); // caller == from selects transfer over transferFrom

        _deployMarket(cellA(), defaultParams());
        IERC20 tranche = trancheIdx == 0 ? IERC20(address(seniorTranche)) : trancheIdx == 1 ? IERC20(address(juniorTranche)) : IERC20(address(liquidityProviderTranche));

        _seedActorWithShares(trancheIdx, from);

        if (_blacklistConfigured) _configureBlacklist(_flagCaller, _flagFrom, _flagTo, caller, from, to);

        uint256 amount = bound(_amount, 0, tranche.balanceOf(from)); // zero through the full balance, incl. the zero-value edge
        if (caller != from) {
            vm.prank(from);
            tranche.approve(caller, amount);
        }

        // Independent outcome derivation. An address is blacklisted iff any flag naming an aliasing role is
        // set, and the hook screens caller, then sender, then receiver, so the first flagged one is the error's account
        address blacklistHit = address(0);
        if (_blacklistConfigured) {
            if (_flagCaller || (_flagFrom && caller == from) || (_flagTo && caller == to)) blacklistHit = caller;
            else if (_flagFrom || (_flagCaller && from == caller) || (_flagTo && from == to)) blacklistHit = from;
            else if (_flagTo || (_flagCaller && to == caller) || (_flagFrom && to == from)) blacklistHit = to;
        }
        uint256 fromBalanceBefore = tranche.balanceOf(from);
        uint256 toBalanceBefore = tranche.balanceOf(to);

        if (blacklistHit != address(0)) vm.expectRevert(abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, blacklistHit));
        vm.prank(caller);
        bool success = caller == from ? tranche.transfer(to, amount) : tranche.transferFrom(from, to, amount);

        if (blacklistHit == address(0)) {
            assertTrue(success, "an authorized transfer must succeed");
            if (from == to) {
                assertEq(tranche.balanceOf(from), fromBalanceBefore, "a self-transfer must leave the balance unchanged");
            } else {
                assertEq(tranche.balanceOf(from), fromBalanceBefore - amount, "the sender must lose exactly the transferred amount");
                assertEq(tranche.balanceOf(to), toBalanceBefore + amount, "the receiver must gain exactly the transferred amount");
            }
        }
    }
}
