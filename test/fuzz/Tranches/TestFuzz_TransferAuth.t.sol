// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoBlacklist } from "../../../src/auth/RoycoBlacklist.sol";
import { JT_LP_ROLE, ST_LP_ROLE } from "../../../src/factory/RolesConfiguration.sol";
import { IRoycoBlacklist } from "../../../src/interfaces/IRoycoBlacklist.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { FixtureCell, MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title TestFuzz_TransferAuth_Tranches
 * @notice Fuzzes every caller/sender/receiver share-transfer authorization combination on all three
 *         tranches: every transfer routes through the kernel's pre-balance-update hook, which screens the
 *         caller, sender, and receiver against the market's blacklist and (when the market enforces it)
 *         requires the receiver to be a whitelisted depositor for the tranche
 * @dev The expected outcome is re-derived independently from the fuzzed configuration (who was blacklisted,
 *      what role the receiver holds, which enforcement the market was deployed with) and asserted in both
 *      directions: a predicted revert must revert with exactly the predicted error and account, and a
 *      predicted success must move exactly the transferred balance
 * @dev Senior and junior deposits are role-gated, so their receiver whitelist bites, while liquidity tranche
 *      deposits are public, so its receiver whitelist check passes for every address by construction
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
     * @dev The seeding transfer itself passes the hook: no blacklist is configured yet, and `_from` is granted
     *      the tranche's depositor role first so a whitelist-enforcing market accepts it as receiver. The
     *      liquidity tranche needs no grant because its deposits are public. The LT balance comes from the
     *      fixture's auto-seeded quote-only depth backing the senior deposit (5% of 100e18 plus cushion)
     */
    function _seedActorWithShares(uint256 _trancheIdx, address _from) internal {
        // Coverage after seeding: (100e18 + 50e18) * 0.2 / 50e18 = 0.6 <= 1, so both deposits clear their gates
        _seedMarket(100e18, 50e18);
        if (_trancheIdx == 0) {
            accessManager.grantRole(ST_LP_ROLE, _from, 0);
            uint256 stHalf = seniorTranche.balanceOf(ST_PROVIDER) / 2;
            vm.prank(ST_PROVIDER);
            seniorTranche.transfer(_from, stHalf);
        } else if (_trancheIdx == 1) {
            accessManager.grantRole(JT_LP_ROLE, _from, 0);
            uint256 jtHalf = juniorTranche.balanceOf(JT_PROVIDER) / 2;
            vm.prank(JT_PROVIDER);
            juniorTranche.transfer(_from, jtHalf);
        } else {
            uint256 ltHalf = liquidityTranche.balanceOf(LT_PROVIDER) / 2;
            vm.prank(LT_PROVIDER);
            liquidityTranche.transfer(_from, ltHalf);
        }
    }

    /// @notice Deploys the production blacklist behind a proxy, wires it into the kernel, and blacklists one account per set flag
    function _configureBlacklist(bool _flagCaller, bool _flagFrom, bool _flagTo, address _caller, address _from, address _to) internal {
        RoycoBlacklist blacklist = RoycoBlacklist(
            address(
                new ERC1967Proxy(
                    address(new RoycoBlacklist()), abi.encodeCall(RoycoBlacklist.initialize, (address(accessManager), address(0), new address[](0)))
                )
            )
        );
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
     * Property: a tranche share transfer succeeds if and only if no involved party is blacklisted and the
     * receiver clears the market's transfer whitelist. The production hook screens in a fixed order — caller,
     * then sender, then receiver against the blacklist, then the receiver against the whitelist — so the
     * expected error and its offending account are re-derived here from the fuzzed flags alone (union of the
     * flags per address, since aliased actors share one blacklist entry) and matched exactly. On the success
     * leg the balances must move by exactly the transferred amount
     */
    function testFuzz_TrancheTransfer_AuthorizedExactlyWhenNoPartyBlacklistedAndReceiverWhitelisted(
        uint256 _trancheIdx,
        uint256 _fromIdx,
        uint256 _toIdx,
        uint256 _callerIdx,
        bool _enforceWhitelist,
        bool _toHoldsDepositRole,
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

        // Deploy the market with the fuzzed whitelist enforcement (an immutable on the kernel)
        MarketParamsConfig memory params = defaultParams();
        params.enforceWhitelistOnTransfer = _enforceWhitelist;
        _deployMarket(cellA(), params);
        IERC20 tranche = trancheIdx == 0 ? IERC20(address(seniorTranche)) : trancheIdx == 1 ? IERC20(address(juniorTranche)) : IERC20(address(liquidityTranche));

        _seedActorWithShares(trancheIdx, from);

        // Set the receiver's depositor-role membership per the fuzzed axis AFTER seeding, so it also overrides
        // the seeding grant when the receiver aliases the sender. The liquidity tranche's deposit is public, so
        // its receiver is whitelisted regardless of any role
        bool receiverWhitelisted = true;
        if (trancheIdx != 2) {
            uint64 depositRole = trancheIdx == 0 ? ST_LP_ROLE : JT_LP_ROLE;
            if (_toHoldsDepositRole) accessManager.grantRole(depositRole, to, 0);
            else accessManager.revokeRole(depositRole, to);
            receiverWhitelisted = _toHoldsDepositRole;
        }

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
        bool whitelistBlocked = _enforceWhitelist && !receiverWhitelisted;

        uint256 fromBalanceBefore = tranche.balanceOf(from);
        uint256 toBalanceBefore = tranche.balanceOf(to);

        if (blacklistHit != address(0)) {
            vm.expectRevert(abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, blacklistHit));
        } else if (whitelistBlocked) {
            vm.expectRevert(abi.encodeWithSelector(IRoycoDayKernel.ACCOUNT_NOT_WHITELISTED_TRANCHE_LP.selector, to));
        }
        vm.prank(caller);
        bool success = caller == from ? tranche.transfer(to, amount) : tranche.transferFrom(from, to, amount);

        if (blacklistHit == address(0) && !whitelistBlocked) {
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
