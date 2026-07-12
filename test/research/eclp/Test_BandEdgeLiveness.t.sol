// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { FixedPoint } from "../../../lib/balancer-v3-monorepo/pkg/solidity-utils/contracts/math/FixedPoint.sol";
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
}
