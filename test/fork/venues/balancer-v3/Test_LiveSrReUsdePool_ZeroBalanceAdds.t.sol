// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRouter } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IRouter.sol";
import { IVault } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { stdError } from "../../../../lib/forge-std/src/StdError.sol";
import { Test } from "../../../../lib/forge-std/src/Test.sol";
import { IRoycoLiquidityProviderTranche } from "../../../../src/interfaces/IRoycoLiquidityProviderTranche.sol";

/// @dev The minimal Permit2 surface the Balancer Router's token pulls require (no permit2 lib is vendored).
interface IPermit2Like {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/**
 * @title Test_LiveSrReUsdePool_ZeroBalanceAdds
 * @notice Fork test against the LIVE mainnet sr-reUSDe/USD1 Gyro E-CLP pool in its as-deployed state — the pool
 *         holds ZERO senior tranche shares and only quote (USD1) — proving the Vault-level add semantics at a
 *         zero token balance by executing the real add operations through Balancer's canonical V3 Router:
 *
 *         1. An UNBALANCED add of `[0 sr-reUSDe, q USD1]` reverts with an arithmetic panic (0x11) for ANY `q`:
 *            `BasePoolMath.computeAddLiquidityUnbalanced` computes `currentBalances[i] + exactAmounts[i] - 1`
 *            per token, which underflows for a token whose pool balance and amount-in are both zero.
 *         2. A PROPORTIONAL add succeeds at any size and pulls ONLY USD1 (the zero-balance token's proportional
 *            leg is zero), minting exactly the requested BPT — no fee, no invariant-ratio bound.
 *
 *         Also pins the kernel-path consequence: the LP tranche's quote-only multi-asset deposit routes through
 *         the kernel's UNBALANCED add, so it reverts with the same panic while the pool holds no senior shares,
 *         while a deposit with a collateral leg (which mints senior shares into the add) succeeds.
 *
 * @dev Requires env `MAINNET_RPC_URL`. The fork is pinned shortly after the market's deployment
 *      (pool created and seeded quote-only in block 25801148 on 2026-08-21).
 */
contract Test_LiveSrReUsdePool_ZeroBalanceAdds is Test {
    // ── Live mainnet deployment (sr-reUSDe market, deployed 2026-08-21) ──────────────────────────────────────────
    address internal constant POOL = 0xdA829C0549733F16B394F7531B40ebd1cfd5D7f1; // Gyro E-CLP sr-reUSDe/USD1
    address internal constant SLP_TRANCHE = 0x0C063Cbb02c89EB2eD5F3E3e38a1F32615366219; // slp-reUSDe LP tranche
    address internal constant SR_REUSDE = 0x455aD9e031236Bc3A0578e2b0e9302D9e70F7eAC; // pool token 0 (senior shares)
    address internal constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d; // pool token 1 (quote)

    // ── Canonical Balancer V3 + Permit2 infra ────────────────────────────────────────────────────────────────────
    address internal constant VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address internal constant ROUTER = 0xAE563E3f8219521950555F5962419C8919758Ea2; // 20250307-v3-router-v2
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Pinned after the pool's creation block (25801148) so the fork carries the live zero-ST-balance state
    uint256 internal constant FORK_BLOCK = 25_803_700;

    /// @dev Pool token registration order (a venue-initialization invariant mirrored from the kernel's venue logic)
    uint256 internal constant ST_SHARE_POOL_INDEX = 0;
    uint256 internal constant QUOTE_ASSET_POOL_INDEX = 1;

    /// @dev The external LP that performs the adds through the Router
    address internal LP;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);

        // Fund an external LP with quote and route its Router pulls through Permit2
        LP = makeAddr("EXTERNAL_LP");
        deal(USD1, LP, 1_000_000e18);
        vm.startPrank(LP);
        IERC20(USD1).approve(PERMIT2, type(uint256).max);
        IPermit2Like(PERMIT2).approve(USD1, ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();

        // Precondition the whole suite rests on: the live pool holds ZERO senior shares and only quote
        uint256[] memory balances = IVault(VAULT).getCurrentLiveBalances(POOL);
        assertEq(balances[ST_SHARE_POOL_INDEX], 0, "precondition: pool must hold zero sr-reUSDe");
        assertGt(balances[QUOTE_ASSET_POOL_INDEX], 0, "precondition: pool must hold USD1");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. UNBALANCED single-sided quote add — reverts for any size
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice An UNBALANCED add of only USD1 panics with an arithmetic underflow regardless of the amount:
    ///         the Vault's per-token `balance + amountIn - 1` rounding adjustment underflows on the
    ///         zero-balance sr-reUSDe leg before any invariant math or ratio bound is reached
    function test_UnbalancedSingleSidedQuoteAdd_RevertsWithArithmeticPanic() public {
        uint256[] memory quoteAmounts = new uint256[](3);
        quoteAmounts[0] = 1; // 1 wei
        quoteAmounts[1] = 1e18; // within the 5x invariant-ratio bound
        quoteAmounts[2] = 100e18; // far beyond the 5x invariant-ratio bound

        for (uint256 i = 0; i < quoteAmounts.length; ++i) {
            uint256[] memory exactAmountsIn = new uint256[](2);
            exactAmountsIn[QUOTE_ASSET_POOL_INDEX] = quoteAmounts[i];

            vm.prank(LP);
            vm.expectRevert(stdError.arithmeticError);
            IRouter(ROUTER).addLiquidityUnbalanced(POOL, exactAmountsIn, 0, false, "");
        }
    }

    /// @notice Control: the underflow is specific to the zero-amount-on-zero-balance leg — the same UNBALANCED
    ///         add escapes the panic once it carries any nonzero sr-reUSDe amount (it then fails later, on the
    ///         Vault's token-in pull, since the LP holds no senior shares — NOT on arithmetic)
    function test_UnbalancedAdd_WithNonZeroSeniorLeg_PassesTheArithmetic() public {
        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[ST_SHARE_POOL_INDEX] = 1; // 1 wei of sr-reUSDe defuses the `0 + 0 - 1` underflow
        exactAmountsIn[QUOTE_ASSET_POOL_INDEX] = 1e18;

        vm.prank(LP);
        (bool success, bytes memory returnData) = ROUTER.call(
            abi.encodeCall(IRouter.addLiquidityUnbalanced, (POOL, exactAmountsIn, 0, false, ""))
        );

        assertFalse(success, "must still revert: the LP holds no sr-reUSDe to settle the pull");
        assertNotEq(bytes4(returnData), bytes4(stdError.arithmeticError), "but no longer with the arithmetic panic");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. PROPORTIONAL add — succeeds single-sided in quote, at any size
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice A PROPORTIONAL add against the drained pool succeeds and is effectively a single-sided USD1
    ///         deposit: the zero-balance sr-reUSDe leg prices to zero, exactly the requested BPT is minted, and
    ///         the 100x supply growth proves the unbalanced-only invariant-ratio bound (5x) does not apply
    function test_ProportionalAdd_SucceedsPullingOnlyQuote() public {
        uint256 bptSupplyBefore = IERC20(POOL).totalSupply();
        uint256 lpQuoteBefore = IERC20(USD1).balanceOf(LP);
        uint256[] memory balancesBefore = IVault(VAULT).getCurrentLiveBalances(POOL);

        // Grow the pool 100x in one add — far beyond the 5x cap that would bound an UNBALANCED add
        uint256 exactBptAmountOut = bptSupplyBefore * 100;
        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[ST_SHARE_POOL_INDEX] = 0; // the LP holds no sr-reUSDe: the add must not ask for any
        maxAmountsIn[QUOTE_ASSET_POOL_INDEX] = type(uint128).max;

        vm.prank(LP);
        uint256[] memory amountsIn = IRouter(ROUTER).addLiquidityProportional(POOL, maxAmountsIn, exactBptAmountOut, false, "");

        // Only quote was pulled, proportional to the requested supply growth (rounding up favors the Vault)
        assertEq(amountsIn[ST_SHARE_POOL_INDEX], 0, "no sr-reUSDe pulled");
        assertApproxEqAbs(
            amountsIn[QUOTE_ASSET_POOL_INDEX],
            balancesBefore[QUOTE_ASSET_POOL_INDEX] * 100,
            1e6,
            "quote pulled ~100x the pool's quote balance"
        );
        assertEq(IERC20(USD1).balanceOf(LP), lpQuoteBefore - amountsIn[QUOTE_ASSET_POOL_INDEX], "LP paid exactly the pulled quote");

        // Exactly the requested BPT was minted to the LP
        assertEq(IERC20(POOL).balanceOf(LP), exactBptAmountOut, "LP received the exact BPT requested");
        assertEq(IERC20(POOL).totalSupply(), bptSupplyBefore + exactBptAmountOut, "supply grew by exactly the mint");

        // The pool deepened on the quote side only: still zero sr-reUSDe, still pinned at the beta price bound
        uint256[] memory balancesAfter = IVault(VAULT).getCurrentLiveBalances(POOL);
        assertEq(balancesAfter[ST_SHARE_POOL_INDEX], 0, "pool still holds zero sr-reUSDe");
        assertEq(
            balancesAfter[QUOTE_ASSET_POOL_INDEX],
            balancesBefore[QUOTE_ASSET_POOL_INDEX] + amountsIn[QUOTE_ASSET_POOL_INDEX],
            "pool quote balance grew by the pulled amount"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. Kernel-path consequence — quote-only LP tranche deposits hit the same panic
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The kernel's post-init adds are UNBALANCED, so a quote-only multi-asset LP deposit (no collateral
    ///         leg, hence zero senior shares into the add) bubbles the same arithmetic panic while the pool holds
    ///         no senior shares — the preview routes through the real deposit path under its real semantics
    function test_KernelQuoteOnlyLptDeposit_RevertsWhilePoolHoldsNoSeniorShares() public {
        vm.expectRevert(stdError.arithmeticError);
        IRoycoLiquidityProviderTranche(SLP_TRANCHE).previewDepositMultiAsset(0, 1e18);
    }

    /// @notice Control: the same deposit with a collateral leg succeeds — its senior leg mints sr-reUSDe into
    ///         the add, giving the zero-balance token a nonzero amount and defusing the underflow
    function test_KernelBothLegLptDeposit_SucceedsWhilePoolHoldsNoSeniorShares() public {
        (uint256 shares, uint256 lptAssetsOut) = IRoycoLiquidityProviderTranche(SLP_TRANCHE).previewDepositMultiAsset(0.1e18, 0.1e18);
        assertGt(shares, 0, "both-leg deposit mints LP tranche shares");
        assertGt(lptAssetsOut, 0, "both-leg deposit mints LPT assets (BPT)");
    }
}
