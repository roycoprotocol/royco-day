// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { C4BatteryBase } from "./Test_C4FullBattery.t.sol";

/**
 * @title Test_SwapSeedsZeroLeg
 * @notice Follow-up to the review question: after a single-sided initialization, can a swap put the empty
 *         token back and clear the Panic(0x11)? And if so, is that the same thing as having initialized with
 *         dust on that side? Measures both, including how small the fixing swap is allowed to be and how far
 *         it moves the pool away from the composition the single-sided initialization intended.
 *
 *         Regenerate: forge test --match-path test/research/eclp/Test_SwapSeedsZeroLeg.t.sol -vv | grep -E "METRIC|VERDICT"
 */
contract Test_SwapSeedsZeroLeg is C4BatteryBase {
    /// Seeds a fresh C4 pool at the given raw balances and points `pool` at it.
    function _seedPool(bytes32 salt, uint256 stRaw, uint256 qRaw) internal {
        address p = _createPool(_eclpParamsC4(), _derivedParamsC4(), false, salt);
        IERC20(p).approve(address(router), type(uint256).max);
        router.initialize(p, address(this), _tokens(), _two(stRaw, qRaw));
        pool = p;
    }

    /// Attempts an unbalanced add; reports only whether it succeeded.
    function _tryUnbalancedAdd(uint256 stIn, uint256 qIn) internal returns (bool) {
        try router.addLiquidityUnbalanced(pool, address(this), _tokens(), _two(stIn, qIn), 0) returns (
            uint256[] memory, uint256 bpt
        ) {
            return bpt > 0;
        } catch {
            return false;
        }
    }

    /// Attempts to sell `amtIn` of the senior share token into the pool for quote.
    function _trySellSt(uint256 amtIn) internal returns (bool) {
        vm.prank(arber);
        try router.swapExactIn(pool, arber, IERC20(address(st)), IERC20(address(quoteToken)), amtIn, 0) returns (
            uint256 out
        ) {
            return out > 0;
        } catch {
            return false;
        }
    }

    /// Attempts to sell `amtIn` of quote into the pool for senior shares.
    function _trySellQuote(uint256 amtIn) internal returns (bool) {
        vm.prank(arber);
        try router.swapExactIn(pool, arber, IERC20(address(quoteToken)), IERC20(address(st)), amtIn, 0) returns (
            uint256 out
        ) {
            return out > 0;
        } catch {
            return false;
        }
    }

    /**
     * @notice A swap into the empty token does clear the zero and restores the unbalanced add
     * @dev Both directions, and only the direction that trades INTO the empty side works
     */
    function test_SwapIntoTheEmptyTokenClearsTheZero() public {
        // Beta state: senior leg exactly zero. Selling senior shares in is the direction that fills it.
        _seedPool(bytes32(uint256(3101)), 0, 1_000_000e18);
        assertFalse(_tryUnbalancedAdd(0, 10_000e18), "precondition: the quote add must fail at the zero senior leg");

        _seedPool(bytes32(uint256(3102)), 0, 1_000_000e18);
        assertFalse(_trySellQuote(10_000e18), "beta: buying senior shares the pool does not hold must revert");
        assertTrue(_trySellSt(10_000e18), "beta: selling senior shares INTO the pool must succeed");
        (uint256 stAfter,) = _rawBalances();
        assertGt(stAfter, 0, "beta: the swap must leave the senior leg nonzero");
        assertTrue(_tryUnbalancedAdd(0, 10_000e18), "beta: after the swap the quote add must work");

        // Alpha state: quote leg exactly zero. Mirrored.
        _seedPool(bytes32(uint256(3103)), 1_000_000e18, 0);
        assertFalse(_tryUnbalancedAdd(10_000e18, 0), "precondition: the senior add must fail at the zero quote leg");

        _seedPool(bytes32(uint256(3104)), 1_000_000e18, 0);
        assertFalse(_trySellSt(10_000e18), "alpha: selling senior shares for quote the pool does not hold must revert");
        assertTrue(_trySellQuote(10_000e18), "alpha: selling quote INTO the pool must succeed");
        (, uint256 qAfter) = _rawBalances();
        assertGt(qAfter, 0, "alpha: the swap must leave the quote leg nonzero");
        assertTrue(_tryUnbalancedAdd(10_000e18, 0), "alpha: after the swap the senior add must work");

        _logMetric("SWAP_SEED", string.concat("beta_st_after=", _u(stAfter), "|alpha_q_after=", _u(qAfter)));
        _logVerdict(
            "swap_seeds_zero_leg",
            "A_SWAP_INTO_THE_EMPTY_SIDE_CLEARS_IT",
            "only the direction that trades into the empty token works, and it restores the unbalanced add"
        );
    }

    /**
     * @notice The fixing swap has a floor: it cannot be dust, so it moves the pool more than dust seeding does
     * @dev This is the difference between initializing with dust and initializing then swapping
     */
    function test_TheFixingSwapCannotBeDust() public {
        // Sweep upward for the smallest senior-share sale that the vault accepts at the beta state.
        uint256 smallest;
        uint256[8] memory probes = [uint256(1), 1e6, 2e6, 5e6, 1e7, 1e8, 5e8, 1e9];
        for (uint256 i = 0; i < probes.length; ++i) {
            _seedPool(bytes32(uint256(3200 + i)), 0, 1_000_000e18);
            if (_trySellSt(probes[i])) {
                smallest = probes[i];
                break;
            }
        }
        assertGt(smallest, 0, "some senior-share sale size must be accepted");
        assertGt(smallest, 1, "one wei must NOT be an accepted swap size, unlike a one-wei dust seed");

        // At that smallest accepted size, record what the pool actually holds afterwards.
        _seedPool(bytes32(uint256(3210)), 0, 1_000_000e18);
        assertTrue(_trySellSt(smallest), "the smallest accepted size must reproduce");
        (uint256 stAfter, uint256 qAfter) = _rawBalances();

        // But the move it causes is negligible: the quote taken out is far below a millionth of one token.
        uint256 quoteRemoved = 1_000_000e18 - qAfter;
        assertLt(quoteRemoved, 1e12, "the smallest accepted swap must move the quote leg by under a millionth of a token");

        // A one-wei dust seed reaches the same unblocked state without any swap and without moving the quote leg.
        _seedPool(bytes32(uint256(3211)), 1, 1_000_000e18);
        (uint256 stDust, uint256 qDust) = _rawBalances();
        assertTrue(_tryUnbalancedAdd(0, 10_000e18), "the one-wei dust seed must unblock the add with no swap at all");
        assertEq(stDust, 1, "the dust seed leaves the senior leg at exactly one wei");
        assertEq(qDust, 1_000_000e18, "the dust seed leaves the quote leg untouched");

        _logMetric(
            "SWAP_FLOOR",
            string.concat(
                "smallest_accepted_swap=", _u(smallest),
                "|st_after_swap=", _u(stAfter),
                "|q_after_swap=", _u(qAfter),
                "|st_after_dust=", _u(stDust),
                "|q_after_dust=", _u(qDust)
            )
        );
        _logVerdict(
            "swap_vs_dust_end_state",
            "THE_SWAP_HAS_A_SIZE_FLOOR_BUT_THE_MOVE_IS_NEGLIGIBLE",
            "one wei is rejected as a swap, but the smallest accepted swap shifts the pool by well under a millionth of a token, so the two routes end up in the same place economically"
        );
    }

    /**
     * @notice Between the single-sided initialization and the fixing swap, deposits revert
     * @dev This is the window that dust seeding removes and the swap route does not
     */
    function test_DepositsRevertInTheWindowBeforeTheSwap() public {
        _seedPool(bytes32(uint256(3301)), 0, 1_000_000e18);

        // The window: the pool is live, it quotes, it holds a million of quote, and deposits still revert.
        assertFalse(_tryUnbalancedAdd(0, 10_000e18), "a quote deposit in the window must revert");
        assertFalse(_tryUnbalancedAdd(0, 1e24), "a large quote deposit in the window must also revert");

        // Anyone can close the window, but only by holding and selling the senior share token.
        assertTrue(_trySellSt(10_000e18), "the window closes only when someone sells senior shares in");
        assertTrue(_tryUnbalancedAdd(0, 10_000e18), "after that, deposits work");

        _logVerdict(
            "window_before_the_swap",
            "DEPOSITS_REVERT_UNTIL_SOMEONE_SWAPS",
            "the swap route needs an external actor holding the missing token; dust seeding needs no one"
        );
    }
}
