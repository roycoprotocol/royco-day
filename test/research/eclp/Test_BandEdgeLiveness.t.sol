// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { FixedPoint } from "../../../lib/balancer-v3-monorepo/pkg/solidity-utils/contracts/math/FixedPoint.sol";
import {
    RemoveLiquidityKind,
    RemoveLiquidityParams
} from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { C4BatteryBase } from "./Test_C4FullBattery.t.sol";

/**
 * @title Test_BandEdgeLiveness
 * @notice T10: the "can the pool brick?" battery. E-CLP params are immutable, so the worst case must be
 *         understood exactly: what still works when the pool is pinned AT its band floor (alpha, all-ST,
 *         zero stables to give) and what un-pins it. The band edge is a RESTING state, not a failure
 *         state — this test drives the shipped C4 pool to ~total stable exhaustion on the real vault and
 *         asserts, operation by operation: exits in the drained direction fail gracefully (revert, no
 *         value loss), restock swaps / stable adds / proportional removes all keep working, and a single
 *         restock swap restores exit service. Also probes the beta corner via a fresh all-stables pool.
 *
 *         Regenerate: forge test --match-path test/research/eclp/Test_BandEdgeLiveness.t.sol -vv | grep -E "METRIC|VERDICT"
 */
contract Test_BandEdgeLiveness is C4BatteryBase {
    using FixedPoint for uint256;

    /// Drive the pool to the alpha corner and probe every operation class against the real vault.
    function test_T10_AlphaCorner_NothingBricks_RestockRestoresService() public {
        _useC4();

        // 1. Exhaust the stables: exiters take all but 1 token of the 10M quote leg.
        router.swapExactOut(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), Y0 - 1e18, type(uint256).max);
        (, uint256 qLeft) = _rawBalances();
        uint256 spotFloor = _spotPrice();
        assertLe(qLeft, 1e18, "the drain must leave at most the 1-token dust target");
        assertApproxEqAbs(spotFloor, 980_392_156_862_745_098, 5e13, "a stable-exhausted pool must rest ON the alpha floor");

        // 2. Exits in the drained direction fail GRACEFULLY: a further ST sell reverts (no stables to give),
        //    taking nothing from the seller.
        uint256 stBefore = st.balanceOf(exiter);
        vm.prank(exiter);
        try router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), 1_000_000e18, 1e18) {
            revert("an exit swap against an exhausted quote leg must revert");
        } catch { }
        assertEq(st.balanceOf(exiter), stBefore, "a reverted exit must leave the exiter's balance untouched");

        // 3. Restock swaps WORK at the corner: buying ST with stables is the un-pinning operation.
        (uint256 snapA, uint256 tsA) = _snapState();
        uint256 stOut = router.swapExactIn(pool, arber, IERC20(address(quoteToken)), IERC20(address(st)), 1_000_000e18, 0);
        assertGt(stOut, 1_000_000e18, "the restock buyer at the floor must receive ST at a discount (more ST-NAV than stables paid)");
        assertGt(_spotPrice(), spotFloor, "a restock swap must lift the price off the floor");
        // ...and exit service is RESTORED by that single swap.
        uint256 qOut = router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), 100_000e18, 0);
        assertGt(qOut, 0, "after one restock swap the pool must serve exits again");
        _restoreState(snapA, tsA);

        // 4. Single-sided STABLE adds work at the corner (the LP-side un-pinning path).
        (uint256 snapB, uint256 tsB) = _snapState();
        (int256 costFair,, uint256 bptOut) = _singleSidedAdd(1_000_000e18);
        assertGt(bptOut, 0, "a single-sided stable add at the alpha corner must mint BPT");
        assertLt(costFair, 0, "adding the scarce asset to a floor-pinned pool must be a fair-value GAIN (the rebalancer's credit)");
        uint256 qOutPostAdd = router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), 100_000e18, 0);
        assertGt(qOutPostAdd, 0, "a stable add must restore exit service");
        _restoreState(snapB, tsB);

        // 5. Proportional removals work at the corner: LPs are NEVER locked in, whatever the band state.
        uint256 bpt = IERC20(pool).balanceOf(address(this)) / 10;
        uint256 stBal0 = st.balanceOf(address(this));
        uint256[] memory outs = router.removeLiquidityProportional(pool, address(this), bpt, _tokens());
        assertGt(outs[0], 0, "a proportional remove at the alpha corner must pay the ST leg");
        assertGt(st.balanceOf(address(this)), stBal0, "the removed ST must actually land in the LP's wallet");

        _logMetric(
            "T10_EDGE",
            string.concat(
                "corner=alpha|spot_floor=",
                _u(spotFloor),
                "|quote_left=",
                _u(qLeft),
                "|restock_st_out_per_1M=",
                _u(stOut),
                "|remove_st_leg=",
                _u(outs[0]),
                "|remove_q_leg=",
                _u(outs[1])
            )
        );
        _logVerdict(
            "T10_band_edge_liveness",
            "NO_BRICK_STATE_EXISTS",
            "alpha corner: exit swaps revert gracefully; restock swaps, stable adds, proportional removes all work; one swap restores service"
        );
    }

    /// The beta corner (all stables, zero ST) — the pool's everyday resting state, probed explicitly.
    function test_T10_BetaCorner_AllOperationsWork() public {
        // A fresh C4 pool initialized single-sided in stables IS the beta corner: ST leg exactly zero.
        address b = _createPool(_eclpParamsC4(), _derivedParamsC4(), false, bytes32(uint256(101)));
        IERC20(b).approve(address(router), type(uint256).max); // this contract is the seeder/LP of the fresh pool
        router.initialize(b, address(this), _tokens(), _two(0, 1_000_000e18));
        pool = b;
        (uint256 stRaw,) = _rawBalances();
        assertEq(stRaw, 0, "the one-sided genesis pool must sit at the exact beta corner (zero ST)");

        // Sells of ST INTO the pool work (that is the exit direction, at full inventory readiness)...
        uint256 qOut = router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), 10_000e18, 0);
        assertGt(qOut, 0, "the beta-corner pool must serve exits immediately");
        // ...buys of ST beyond the (tiny) inventory revert gracefully...
        vm.prank(arber);
        try router.swapExactIn(pool, arber, IERC20(address(quoteToken)), IERC20(address(st)), 1_000_000e18, 0) {
            revert("buying more ST than the corner pool holds must revert");
        } catch { }
        // ...and adds + removes work.
        (,, uint256 bptOut) = _singleSidedAdd(100_000e18);
        assertGt(bptOut, 0, "a stable add at the beta corner must mint BPT");
        uint256[] memory outs = router.removeLiquidityProportional(pool, address(this), IERC20(pool).balanceOf(address(this)) / 10, _tokens());
        assertGt(outs[1], 0, "a proportional remove at the beta corner must pay the stable leg");

        _logVerdict("T10_beta_corner", "ALL_OPERATIONS_WORK", "exits served, over-buys revert gracefully, adds and removes live");
    }

    // A leg at exactly zero is a distinct state from a leg at dust, and the two behave differently under
    // unbalanced adds. These cases extend T10 rather than opening a new study.

    SingleTokenRemoveRouter internal stRouter;

    function setUp() public virtual override {
        super.setUp();
        stRouter = new SingleTokenRemoveRouter(IVault(address(vault)));
        IERC20(poolC4).approve(address(stRouter), type(uint256).max);
    }

    /// Seeds a fresh C4 pool at the given raw balances and points `pool` at it.
    function _seedPool(bytes32 salt, uint256 stRaw, uint256 qRaw) internal {
        address p = _createPool(_eclpParamsC4(), _derivedParamsC4(), false, salt);
        IERC20(p).approve(address(router), type(uint256).max);
        IERC20(p).approve(address(stRouter), type(uint256).max);
        router.initialize(p, address(this), _tokens(), _two(stRaw, qRaw));
        pool = p;
    }

    /// True when the caught revert is a Solidity arithmetic panic (0x11) rather than a custom error.
    function _isArithmeticPanic(bytes memory err) internal pure returns (bool) {
        if (err.length < 36) return false;
        bytes4 sel;
        uint256 code;
        assembly {
            sel := mload(add(err, 0x20))
            code := mload(add(err, 0x24))
        }
        return (sel == bytes4(0x4e487b71) && code == 0x11);
    }

    /// Attempts a single-sided unbalanced add; reports success, and whether a failure was an arithmetic panic.
    function _trySingleSidedAdd(uint256 stIn, uint256 qIn) internal returns (bool ok, bool arithmeticPanic) {
        try router
            .addLiquidityUnbalanced(pool, lp, _tokens(), _two(stIn, qIn), 0) returns (uint256[] memory, uint256 bpt) {
            return (bpt > 0, false);
        } catch (bytes memory err) {
            return (false, _isArithmeticPanic(err));
        }
    }

    /**
     * @notice An unbalanced add that would leave a leg at exactly zero reverts with an arithmetic panic
     * @dev The add that fills the empty leg succeeds instead
     * @dev The behavior is the same at both corners
     * @dev One wei in the empty leg is enough to make both directions succeed
     */
    function test_T10_ExactZeroLeg_OnlyTheEmptyLegCanBeFilled() public {
        // Beta corner: the senior leg is exactly zero.
        _seedPool(bytes32(uint256(1101)), 0, 1_000_000e18);
        (bool fillEmpty,) = _trySingleSidedAdd(10_000e18, 0);
        assertTrue(fillEmpty, "beta: filling the empty senior leg must succeed");
        _seedPool(bytes32(uint256(1102)), 0, 1_000_000e18);
        (bool keepEmpty, bool panicB) = _trySingleSidedAdd(0, 10_000e18);
        assertFalse(keepEmpty, "beta: an add that leaves the senior leg at zero must fail");
        assertTrue(panicB, "beta: it fails as an arithmetic panic, not a custom error");

        // Alpha corner: the quote leg is exactly zero. Same shape, mirrored.
        _seedPool(bytes32(uint256(1103)), 1_000_000e18, 0);
        (bool fillEmptyA,) = _trySingleSidedAdd(0, 10_000e18);
        assertTrue(fillEmptyA, "alpha: filling the empty quote leg must succeed");
        _seedPool(bytes32(uint256(1104)), 1_000_000e18, 0);
        (bool keepEmptyA, bool panicA) = _trySingleSidedAdd(10_000e18, 0);
        assertFalse(keepEmptyA, "alpha: an add that leaves the quote leg at zero must fail");
        assertTrue(panicA, "alpha: it fails as an arithmetic panic, not a custom error");

        // One wei in the empty leg is enough to clear it in both directions.
        _seedPool(bytes32(uint256(1105)), 1, 1_000_000e18);
        (bool dustQ,) = _trySingleSidedAdd(0, 10_000e18);
        assertTrue(dustQ, "one wei of senior shares must unblock the quote add");
        _seedPool(bytes32(uint256(1106)), 1_000_000e18, 1);
        (bool dustST,) = _trySingleSidedAdd(10_000e18, 0);
        assertTrue(dustST, "one wei of quote must unblock the senior add");

        _logVerdict(
            "T10_exact_zero_leg",
            "ONLY_THE_EMPTY_LEG_CAN_BE_FILLED",
            "an add leaving a leg at exactly zero panics (0x11); filling the empty leg works; one wei clears it"
        );
    }

    /**
     * @notice A single-token exact-out remove of a whole leg reaches the same panic from a balanced pool
     * @dev It creates a zero leg rather than leaving one, so the starting state need not be a corner
     * @dev The exact-in variant is stopped by a custom error instead, which is the contrast worth recording
     */
    function test_T10_ExactOutRemove_WholeLegPanicsEvenFromBalanced() public {
        _useC4();
        (uint256 stRaw, uint256 qRaw) = _rawBalances();
        uint256 bpt = IERC20(poolC4).balanceOf(address(this));
        assertGt(stRaw, 0, "the balanced pool must hold both legs");
        assertGt(qRaw, 0, "the balanced pool must hold both legs");

        // Pulling the whole senior leg out single-sided panics, from an ordinary balanced state.
        (uint256 snap, uint256 ts) = _snapState();
        bool stPanic;
        try stRouter.removeSingleExactOut(poolC4, address(this), _tokens(), 0, stRaw, bpt) {
            revert("an exact-out remove of the whole senior leg must not succeed");
        } catch (bytes memory err) {
            stPanic = _isArithmeticPanic(err);
        }
        assertTrue(stPanic, "exact-out of the whole senior leg must fail as an arithmetic panic");
        _restoreState(snap, ts);

        // The quote leg behaves the same way.
        (snap, ts) = _snapState();
        bool qPanic;
        try stRouter.removeSingleExactOut(poolC4, address(this), _tokens(), 1, qRaw, bpt) {
            revert("an exact-out remove of the whole quote leg must not succeed");
        } catch (bytes memory err) {
            qPanic = _isArithmeticPanic(err);
        }
        assertTrue(qPanic, "exact-out of the whole quote leg must fail as an arithmetic panic");
        _restoreState(snap, ts);

        // The exact-in variant fails with a custom error (InvariantRatioBelowMin).
        (snap, ts) = _snapState();
        bool exactInNamed;
        try stRouter.removeSingleExactIn(poolC4, address(this), _tokens(), 0, bpt / 2) {
            revert("burning half the pool tokens into the senior leg must not succeed");
        } catch (bytes memory err) {
            exactInNamed = !_isArithmeticPanic(err);
        }
        assertTrue(exactInNamed, "the exact-in variant must fail with a custom error, not a panic");
        _restoreState(snap, ts);

        _logVerdict(
            "T10_exact_out_remove",
            "ZERO_LEG_PANICS_FROM_ANY_STATE",
            "exact-out removal of a whole leg panics (0x11) even from a balanced pool; exact-in uses a custom error"
        );
    }

    /// A leg reaches exactly zero only at initialization: no swap can drain a dust-seeded leg back to zero.
    function test_T10_ExactZeroIsGenesisOnly_SwapsCannotDrainToZero() public {
        _seedPool(bytes32(uint256(1107)), 1e6, 1_000_000e18);
        (uint256 st0,) = _rawBalances();

        // Buying the whole senior leg out exact-out must revert on a custom error.
        (uint256 snap, uint256 ts) = _snapState();
        vm.prank(arber);
        try router.swapExactOut(pool, arber, IERC20(address(quoteToken)), IERC20(address(st)), st0, type(uint256).max) {
            revert("draining the senior leg to exactly zero by exact-out must revert");
        } catch { }
        _restoreState(snap, ts);

        // A very large exact-in buy must revert as well, rather than zero the leg.
        (snap, ts) = _snapState();
        vm.prank(arber);
        try router.swapExactIn(pool, arber, IERC20(address(quoteToken)), IERC20(address(st)), 5_000_000e18, 0) {
            revert("draining the senior leg to exactly zero by exact-in must revert");
        } catch { }
        _restoreState(snap, ts);

        // The dust survives, so the quote add still works.
        (bool ok,) = _trySingleSidedAdd(0, 10_000e18);
        assertTrue(ok, "the dust seed must survive and keep the quote add live");

        _logVerdict(
            "T10_dust_seed_durability",
            "EXACT_ZERO_IS_GENESIS_ONLY",
            "swaps and single-token removes cannot drain a dust leg to zero, so seeding both legs once closes it"
        );
    }
}

/**
 * @title SingleTokenRemoveRouter
 * @notice Router shim exposing the single-token remove kinds the study router omits, so the tests above can
 *         probe whether an unbalanced remove can drive a pool leg to exactly zero
 */
contract SingleTokenRemoveRouter {
    IVault internal immutable VAULT;

    error OnlyVault();

    constructor(IVault v) {
        VAULT = v;
    }

    modifier onlyVault() {
        if (msg.sender != address(VAULT)) revert OnlyVault();
        _;
    }

    /// Burns at most `maxBptIn` to pull exactly `exactAmountOut` of the token at `idx`.
    function removeSingleExactOut(
        address pool,
        address payer,
        IERC20[] memory tokens,
        uint256 idx,
        uint256 exactAmountOut,
        uint256 maxBptIn
    )
        external
        returns (uint256 bptIn)
    {
        bytes memory hookCall = abi.encodeCall(this.exactOutHook, (pool, payer, tokens, idx, exactAmountOut, maxBptIn));
        return abi.decode(VAULT.unlock(hookCall), (uint256));
    }

    function exactOutHook(
        address pool,
        address payer,
        IERC20[] memory tokens,
        uint256 idx,
        uint256 exactAmountOut,
        uint256 maxBptIn
    )
        external
        onlyVault
        returns (uint256 bptIn)
    {
        // The vault reads the output token from the one non-zero entry in minAmountsOut.
        uint256[] memory mins = new uint256[](tokens.length);
        mins[idx] = exactAmountOut;
        uint256[] memory outs;
        (bptIn, outs,) = VAULT.removeLiquidity(
            RemoveLiquidityParams({
                pool: pool,
                from: payer,
                maxBptAmountIn: maxBptIn,
                minAmountsOut: mins,
                kind: RemoveLiquidityKind.SINGLE_TOKEN_EXACT_OUT,
                userData: ""
            })
        );
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (outs[i] > 0) VAULT.sendTo(tokens[i], payer, outs[i]);
        }
    }

    /// Burns exactly `bptIn`, taking the proceeds out entirely in the token at `idx`.
    function removeSingleExactIn(
        address pool,
        address payer,
        IERC20[] memory tokens,
        uint256 idx,
        uint256 bptIn
    )
        external
        returns (uint256 amountOut)
    {
        return abi.decode(VAULT.unlock(abi.encodeCall(this.exactInHook, (pool, payer, tokens, idx, bptIn))), (uint256));
    }

    function exactInHook(
        address pool,
        address payer,
        IERC20[] memory tokens,
        uint256 idx,
        uint256 bptIn
    )
        external
        onlyVault
        returns (uint256 amountOut)
    {
        // The vault reads the output token from the one non-zero entry in minAmountsOut.
        uint256[] memory mins = new uint256[](tokens.length);
        mins[idx] = 1;
        uint256[] memory outs;
        (, outs,) = VAULT.removeLiquidity(
            RemoveLiquidityParams({
                pool: pool,
                from: payer,
                maxBptAmountIn: bptIn,
                minAmountsOut: mins,
                kind: RemoveLiquidityKind.SINGLE_TOKEN_EXACT_IN,
                userData: ""
            })
        );
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (outs[i] > 0) VAULT.sendTo(tokens[i], payer, outs[i]);
        }
        amountOut = outs[idx];
    }
}
