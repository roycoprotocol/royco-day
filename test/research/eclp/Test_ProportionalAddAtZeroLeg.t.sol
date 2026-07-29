// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
    AddLiquidityKind,
    AddLiquidityParams
} from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { C4BatteryBase } from "./Test_C4FullBattery.t.sol";

/**
 * @title Test_ProportionalAddAtZeroLeg
 * @notice Settles whether the Panic(0x11) at a zero pool leg is a property of the pool state or an artifact
 *         of the add KIND the venue chooses. T10 measured only UNBALANCED adds, because the study router had
 *         no proportional add to call. This adds one and re-runs the same states.
 *
 *         Regenerate: forge test --match-path test/research/eclp/Test_ProportionalAddAtZeroLeg.t.sol -vv | grep -E "METRIC|VERDICT"
 */
contract Test_ProportionalAddAtZeroLeg is C4BatteryBase {
    ProportionalAddRouter internal propRouter;

    function setUp() public virtual override {
        super.setUp();
        propRouter = new ProportionalAddRouter(IVault(address(vault)));
        address[4] memory actors = [lp, arber, exiter, address(this)];
        for (uint256 i = 0; i < 4; ++i) {
            vm.startPrank(actors[i]);
            st.approve(address(propRouter), type(uint256).max);
            quoteToken.approve(address(propRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// Seeds a fresh C4 pool at the given raw balances and points `pool` at it.
    function _seedPool(bytes32 salt, uint256 stRaw, uint256 qRaw) internal {
        address p = _createPool(_eclpParamsC4(), _derivedParamsC4(), false, salt);
        IERC20(p).approve(address(router), type(uint256).max);
        router.initialize(p, address(this), _tokens(), _two(stRaw, qRaw));
        pool = p;
    }

    /// Attempts a proportional add of `bptOut`; reports success and the amounts the vault actually pulled.
    function _tryProportionalAdd(uint256 bptOut) internal returns (bool ok, uint256 stIn, uint256 qIn) {
        try propRouter.addLiquidityProportional(pool, address(this), _tokens(), bptOut) returns (
            uint256[] memory amountsIn
        ) {
            return (true, amountsIn[0], amountsIn[1]);
        } catch {
            return (false, 0, 0);
        }
    }

    /// Attempts an unbalanced add, for the side-by-side contrast on the identical pool state.
    function _tryUnbalancedAdd(uint256 stIn, uint256 qIn) internal returns (bool ok) {
        try router.addLiquidityUnbalanced(pool, address(this), _tokens(), _two(stIn, qIn), 0) returns (
            uint256[] memory, uint256 bpt
        ) {
            return bpt > 0;
        } catch {
            return false;
        }
    }

    /**
     * @notice A proportional add succeeds at a zero pool leg, on the exact state where the unbalanced add panics
     * @dev Both directions, and the contrast is measured on the same pool in the same test
     */
    function test_ProportionalAddWorksWhereUnbalancedPanics() public {
        // Beta state: senior leg exactly zero, quote leg 1M. The venue's UNBALANCED quote add panics here.
        _seedPool(bytes32(uint256(2101)), 0, 1_000_000e18);
        uint256 supply = IERC20(pool).totalSupply();
        assertFalse(_tryUnbalancedAdd(0, 10_000e18), "beta: the unbalanced quote add must still fail (the T10 result)");

        _seedPool(bytes32(uint256(2102)), 0, 1_000_000e18);
        (bool okB, uint256 stInB, uint256 qInB) = _tryProportionalAdd(supply / 10);
        assertTrue(okB, "beta: the PROPORTIONAL add must succeed on the same state");
        assertEq(stInB, 0, "beta: the proportional add must pull exactly zero senior shares");
        assertGt(qInB, 0, "beta: the proportional add must pull quote");

        // Alpha state: quote leg exactly zero, senior leg 1M. Mirrored.
        _seedPool(bytes32(uint256(2103)), 1_000_000e18, 0);
        uint256 supplyA = IERC20(pool).totalSupply();
        assertFalse(_tryUnbalancedAdd(10_000e18, 0), "alpha: the unbalanced senior add must still fail");

        _seedPool(bytes32(uint256(2104)), 1_000_000e18, 0);
        (bool okA, uint256 stInA, uint256 qInA) = _tryProportionalAdd(supplyA / 10);
        assertTrue(okA, "alpha: the PROPORTIONAL add must succeed on the same state");
        assertEq(qInA, 0, "alpha: the proportional add must pull exactly zero quote");
        assertGt(stInA, 0, "alpha: the proportional add must pull senior shares");

        _logMetric(
            "PROP_ZERO_LEG",
            string.concat(
                "beta_prop_st_in=", _u(stInB), "|beta_prop_q_in=", _u(qInB),
                "|alpha_prop_st_in=", _u(stInA), "|alpha_prop_q_in=", _u(qInA)
            )
        );
        _logVerdict(
            "prop_add_at_zero_leg",
            "PROPORTIONAL_SUCCEEDS_WHERE_UNBALANCED_PANICS",
            "the revert is a property of the add KIND, not of the pool state"
        );
    }

    /**
     * @notice The proportional add pulls the exact pro-rata amount and leaves the zero leg at zero
     * @dev This is the limit of the workaround: it never seeds the empty leg, so the state persists
     */
    function test_ProportionalAddIsProRataAndLeavesTheZeroInPlace() public {
        _seedPool(bytes32(uint256(2105)), 0, 1_000_000e18);
        uint256 supply = IERC20(pool).totalSupply();
        (uint256 st0, uint256 q0) = _rawBalances();

        uint256 bptOut = supply / 10;
        (bool ok,, uint256 qIn) = _tryProportionalAdd(bptOut);
        assertTrue(ok, "the proportional add must succeed");

        // Pro-rata to within the vault's round-up: qIn == ceil(q0 * bptOut / supply).
        uint256 expected = (q0 * bptOut + supply - 1) / supply;
        assertEq(qIn, expected, "the quote pulled must be the pro-rata amount rounded up");

        (uint256 st1, uint256 q1) = _rawBalances();
        assertEq(st0, 0, "precondition: the senior leg started at exactly zero");
        assertEq(st1, 0, "the senior leg must STILL be exactly zero after the proportional add");
        assertEq(q1, q0 + qIn, "the quote leg must have grown by exactly the amount pulled");

        // So the next unbalanced add still panics: the workaround does not clear the state.
        assertFalse(_tryUnbalancedAdd(0, 10_000e18), "the zero leg persists, so the unbalanced add still fails");

        _logMetric(
            "PROP_PRO_RATA",
            string.concat("q_in=", _u(qIn), "|expected=", _u(expected), "|st_after=", _u(st1), "|q_after=", _u(q1))
        );
        _logVerdict(
            "prop_add_does_not_clear_zero",
            "ZERO_LEG_PERSISTS",
            "proportional adds avoid the panic but can never seed the empty leg, so the state is permanent"
        );
    }

    /**
     * @notice A proportional add cannot accept senior shares while the senior leg is zero
     * @dev This is what the branch-to-proportional fix would cost: the senior side becomes undepositable
     */
    function test_ProportionalAddCannotAcceptTheEmptyToken() public {
        _seedPool(bytes32(uint256(2106)), 0, 1_000_000e18);
        uint256 supply = IERC20(pool).totalSupply();

        // Whatever BPT is requested, the senior amount pulled is zero. There is no bptOut that takes senior shares.
        (bool ok1, uint256 stIn1,) = _tryProportionalAdd(supply / 100);
        (bool ok2, uint256 stIn2,) = _tryProportionalAdd(supply);
        assertTrue(ok1 && ok2, "both proportional adds must succeed");
        assertEq(stIn1, 0, "a small proportional add pulls zero senior shares");
        assertEq(stIn2, 0, "even a supply-sized proportional add pulls zero senior shares");

        // The unbalanced add is the ONLY kind that can seed the empty leg, and it works in that direction.
        assertTrue(_tryUnbalancedAdd(10_000e18, 0), "the unbalanced add into the EMPTY leg must succeed");
        (uint256 stAfter,) = _rawBalances();
        assertGt(stAfter, 0, "the unbalanced add is what actually clears the zero");

        _logVerdict(
            "prop_add_cannot_seed",
            "ONLY_UNBALANCED_CAN_SEED_THE_EMPTY_LEG",
            "proportional pulls zero of the empty token at every bptOut, so it cannot be the sole add path"
        );
    }
}

/**
 * @title ProportionalAddRouter
 * @notice Router shim exposing the proportional add the study router omits. For AddLiquidityKind.PROPORTIONAL
 *         the vault reads minBptAmountOut as the EXACT BPT to mint and derives the amounts in from it
 */
contract ProportionalAddRouter {
    IVault internal immutable VAULT;

    error OnlyVault();

    constructor(IVault v) {
        VAULT = v;
    }

    modifier onlyVault() {
        if (msg.sender != address(VAULT)) revert OnlyVault();
        _;
    }

    /// Mints exactly `bptOut` to `payer`, pulling whatever pro-rata amounts the vault computes.
    function addLiquidityProportional(
        address pool,
        address payer,
        IERC20[] memory tokens,
        uint256 bptOut
    )
        external
        returns (uint256[] memory amountsIn)
    {
        return abi.decode(
            VAULT.unlock(abi.encodeCall(this.proportionalHook, (pool, payer, tokens, bptOut))), (uint256[])
        );
    }

    function proportionalHook(
        address pool,
        address payer,
        IERC20[] memory tokens,
        uint256 bptOut
    )
        external
        onlyVault
        returns (uint256[] memory amountsIn)
    {
        // A large but finite bound: the vault upscales maxAmountsIn by the token rate, so type(uint256).max
        // overflows there before the add is ever attempted.
        uint256[] memory maxAmountsIn = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            maxAmountsIn[i] = 1e30;
        }
        (amountsIn,,) = VAULT.addLiquidity(
            AddLiquidityParams({
                pool: pool,
                to: payer,
                maxAmountsIn: maxAmountsIn,
                minBptAmountOut: bptOut, // For PROPORTIONAL the vault treats this as the exact BPT out
                kind: AddLiquidityKind.PROPORTIONAL,
                userData: ""
            })
        );
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amountsIn[i] > 0) {
                tokens[i].transferFrom(payer, address(VAULT), amountsIn[i]);
                VAULT.settle(tokens[i], amountsIn[i]);
            }
        }
    }
}
