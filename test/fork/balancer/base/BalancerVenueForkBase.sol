// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { IBasePool } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IBasePool.sol";
import { IRouter } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IRouter.sol";
import { Rounding } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { LPOracleBase } from "../../../../lib/balancer-v3-monorepo/pkg/oracles/contracts/LPOracleBase.sol";
import { GyroECLPPool } from "../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPool.sol";
import { GyroECLPMath } from "../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/lib/GyroECLPMath.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

import { BalancerV3_LT_BPTOracle_Quoter } from "../../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import {
    IPermit2Like,
    Identical_ERC4626_Chainlink_BalancerV3_LT_KernelTest
} from "../../kernels/Identical_ERC4626_Chainlink_BalancerV3_LT/base/Identical_ERC4626_Chainlink_BalancerV3_LT_KernelTest.sol";

/**
 * @title BalancerVenueForkBase
 * @notice Shared scaffolding (NO tests) for the deep Balancer-venue fork suites: external actors that trade
 *         and LP through Balancer's canonical V3 Router, pool composition/price/TVL readers, swap-capacity
 *         probes and skew builders, a liquidity-gate driver, and the derived-bound helpers the tests
 *         assert against. Everything runs on the real forked Vault + Gyro E-CLP pool + E-CLP LP oracle the
 *         deploy template ships — nothing here touches a mock.
 * @dev Transient-cache discipline: foundry executes a whole test as ONE
 *      transaction, so the quoter's transient `ST_SHARE_RATE` cache persists across helper calls. `getRate()`
 *      reads taken BEFORE any kernel op/sync in a test are cache-miss (fresh preview) reads; any read AFTER a
 *      sync observes the frozen cached mark of that sync. Each test states which regime it reads under.
 */
abstract contract BalancerVenueForkBase is Identical_ERC4626_Chainlink_BalancerV3_LT_KernelTest {
    // ═══════════════════════════════════════════════════════════════════════════
    // EXTERNAL ACTORS — trade/LP through the canonical Router, never the kernel
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Creates a labeled external actor with full Router allowances wired: the ST share and the quote
     *         asset through the Permit2 two-step (the Router pulls tokensIn through Permit2), and the BPT
     *         through a plain ERC20 approval (the Vault spends the pool token's allowance directly on burns).
     * @dev Mirrors the allowance wiring of `_initializeLTVenueIfNeeded` (the venue bootstrap).
     */
    function _makeExternalLP(string memory _name) internal returns (address actor) {
        actor = makeAddr(_name);
        address router = _balancerV3Router();
        address permit2 = _canonicalPermit2();
        vm.startPrank(actor);
        IERC20(address(ST)).approve(permit2, type(uint256).max);
        IERC20(testConfig.quoteAsset).approve(permit2, type(uint256).max);
        IPermit2Like(permit2).approve(address(ST), router, type(uint160).max, type(uint48).max);
        IPermit2Like(permit2).approve(testConfig.quoteAsset, router, type(uint160).max, type(uint48).max);
        IERC20(POOL).approve(router, type(uint256).max);
        vm.stopPrank();
    }

    /**
     * @notice Funds an external actor with live ST shares and dealt quote assets.
     * @dev ST shares are transferred from ST_ALICE (the same trick as the venue bootstrap) so funding creates
     *      NO new senior exposure and consults no gate. The ST/JT market must be seeded first (arrange guard).
     */
    function _fundExternalLP(address _actor, uint256 _stShares, uint256 _quoteAssets) internal {
        if (_stShares > 0) {
            assertGe(ST.balanceOf(ST_ALICE_ADDRESS), _stShares, "fund external LP: seed the ST/JT market with enough senior first");
            vm.prank(ST_ALICE_ADDRESS);
            IERC20(address(ST)).transfer(_actor, _stShares);
        }
        if (_quoteAssets > 0) dealQuoteAsset(_actor, _quoteAssets);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROUTER OPS (prank the actor; deadline = now; wethIsEth = false; no userData)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Swaps `_amountIn` of `_tokenIn` for `_tokenOut` through the canonical Router as `_actor`.
    function _swapExactIn(address _actor, address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minOut) internal returns (uint256 amountOut) {
        vm.prank(_actor);
        amountOut =
            IRouter(_balancerV3Router()).swapSingleTokenExactIn(POOL, IERC20(_tokenIn), IERC20(_tokenOut), _amountIn, _minOut, block.timestamp, false, "");
    }

    /**
     * @notice Queries an exact-in swap through the Router's query mode without executing it.
     * @dev Query mode requires the zero tx.origin static-call context; the probe is wrapped in a state
     *      snapshot so no query-mode side effect (including the hook's sync) leaks into the test.
     */
    function _querySwapExactIn(address _tokenIn, address _tokenOut, uint256 _amountIn) internal returns (bool ok, uint256 amountOut) {
        uint256 snapshotId = vm.snapshotState();
        vm.prank(address(0), address(0));
        (bool success, bytes memory ret) = _balancerV3Router()
            .call(abi.encodeCall(IRouter.querySwapSingleTokenExactIn, (POOL, IERC20(_tokenIn), IERC20(_tokenOut), _amountIn, address(0), "")));
        vm.revertToState(snapshotId);
        ok = success;
        if (success) amountOut = abi.decode(ret, (uint256));
    }

    /// @notice External unbalanced add through the Router; amounts ordered by pool registration index.
    function _externalAddUnbalanced(address _actor, uint256 _stShares, uint256 _quoteAssets, uint256 _minBptOut) internal returns (uint256 bptOut) {
        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[_stPoolIndex()] = _stShares;
        exactAmountsIn[_quotePoolIndex()] = _quoteAssets;
        vm.prank(_actor);
        bptOut = IRouter(_balancerV3Router()).addLiquidityUnbalanced(POOL, exactAmountsIn, _minBptOut, false, "");
    }

    /**
     * @notice External proportional add through the Router for an exact BPT amount out.
     * @dev `maxAmountsIn` is sized from the live proportional amounts padded 2%, so the call carries a real
     *      (non-infinite) ceiling while never binding on rounding.
     */
    function _externalAddProportional(address _actor, uint256 _exactBptOut) internal returns (uint256[] memory amountsIn) {
        uint256[] memory rawBalances = _rawBalances();
        uint256 bptSupply = _bptSupply();
        uint256[] memory maxAmountsIn = new uint256[](2);
        for (uint256 i = 0; i < 2; ++i) {
            maxAmountsIn[i] = Math.mulDiv(rawBalances[i], _exactBptOut, bptSupply) * 102 / 100 + 2;
        }
        vm.prank(_actor);
        amountsIn = IRouter(_balancerV3Router()).addLiquidityProportional(POOL, maxAmountsIn, _exactBptOut, false, "");
    }

    /// @notice External proportional remove through the Router (min-outs zero; assertions live in the tests).
    function _externalRemoveProportional(address _actor, uint256 _bptIn) internal returns (uint256[] memory amountsOut) {
        vm.prank(_actor);
        amountsOut = IRouter(_balancerV3Router()).removeLiquidityProportional(POOL, _bptIn, new uint256[](2), false, "");
    }

    /// @notice External single-token exact-in remove through the Router.
    /// @dev The min-out floor is at least 1 wei: the Vault locates the output token as the single NON-ZERO
    ///      entry of `minAmountsOut` (`InputHelpers.getSingleInputIndex`), so a zero floor is `AllZeroInputs`.
    function _externalRemoveSingleTokenExactIn(address _actor, uint256 _bptIn, address _tokenOut) internal returns (uint256 amountOut) {
        vm.prank(_actor);
        amountOut = IRouter(_balancerV3Router()).removeLiquiditySingleTokenExactIn(POOL, _bptIn, IERC20(_tokenOut), 1, false, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POOL READERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The senior tranche share's pool registration index (never assume the address sort order).
    function _stPoolIndex() internal view returns (uint256) {
        return address(VAULT.getPoolTokens(POOL)[0]) == address(ST) ? 0 : 1;
    }

    /// @notice The quote asset's pool registration index.
    function _quotePoolIndex() internal view returns (uint256) {
        return 1 - _stPoolIndex();
    }

    /// @notice Live pool balances, scaled to 18 decimals with token rates applied (the ST leg carries `getRate`).
    function _liveBalances() internal view returns (uint256[] memory) {
        return VAULT.getCurrentLiveBalances(POOL);
    }

    /// @notice Raw pool token balances in each token's own decimals.
    function _rawBalances() internal view returns (uint256[] memory balancesRaw) {
        (,, balancesRaw,) = VAULT.getPoolTokenInfo(POOL);
    }

    /// @notice The kernel-wired manipulation-resistant E-CLP LP oracle.
    function _bptOracle() internal view returns (LPOracleBase) {
        return LPOracleBase(BalancerV3_LT_BPTOracle_Quoter(address(KERNEL)).getBalancerV3QuoterState().bptOracle);
    }

    /// @notice The oracle's TVL mark for the whole pool (NAV units, WAD).
    function _poolTVL() internal view returns (uint256) {
        return _bptOracle().computeTVL();
    }

    /// @notice Whether the oracle reverts when read inside `Vault.unlock` (the template deploys with `false`).
    function _oracleShouldRevertIfVaultUnlocked() internal view returns (bool) {
        return _bptOracle().getShouldRevertIfVaultUnlocked();
    }

    /// @notice The BPT total supply (Vault-managed).
    function _bptSupply() internal view returns (uint256) {
        return VAULT.totalSupply(POOL);
    }

    /// @notice The oracle NAV backing one BPT, floored (WAD).
    function _navPerBPTWAD() internal view returns (uint256) {
        return Math.mulDiv(_poolTVL(), WAD, _bptSupply());
    }

    /**
     * @notice Mark-to-market of the actual pool balances at the oracle's feed prices.
     * @dev Both oracle feeds are the constant-1.0 price feed (the ST leg's real pricing enters through the
     *      Vault's rate scaling), so the feed-price MtM is exactly the sum of the live scaled-18 balances.
     */
    function _markToMarketAtFeeds() internal view returns (uint256 mtm) {
        uint256[] memory live = _liveBalances();
        return live[0] + live[1];
    }

    /// @notice The kernel's share of the BPT supply (WAD): the slice of pool TVL that is the LT's.
    function _kernelPoolShareWAD() internal view returns (uint256) {
        return Math.mulDiv(toUint256(KERNEL.getState().ltOwnedYieldBearingAssets), WAD, _bptSupply());
    }

    /// @notice The feed-price mark-to-market backing one BPT (WAD). The economics basis for adder/redeemer
    ///         value accounting — the oracle's `_navPerBPTWAD` marks at the curve-minimum composition instead
    ///         and can sit up to (1 - alpha) below this.
    function _mtmPerBPTWAD() internal view returns (uint256) {
        return Math.mulDiv(_markToMarketAtFeeds(), WAD, _bptSupply());
    }

    /// @notice The pool's static swap fee percentage (WAD), read live — never hardcoded.
    function _staticSwapFeePctWAD() internal view returns (uint256) {
        return VAULT.getStaticSwapFeePercentage(POOL);
    }

    /// @notice The protocol/creator share of collected swap fees (WAD), read live — never hardcoded.
    function _aggregateSwapFeePctWAD() internal view returns (uint256) {
        return VAULT.getPoolConfig(POOL).aggregateSwapFeePercentage;
    }

    /// @notice The ST leg's share of pool value at the feed marks (WAD). The single-sided-add leak scales with `1 - w`.
    function _stValueShareWAD() internal view returns (uint256) {
        uint256[] memory live = _liveBalances();
        return Math.mulDiv(live[_stPoolIndex()], WAD, live[0] + live[1]);
    }

    /**
     * @notice The pool's internal spot price of the (rate-scaled) ST leg in quote units (WAD).
     * @dev `calcSpotPrice0in1` prices token0 in token1; inverted when the ST share registered as token1.
     *      This is the rate-scaled price — the price of one NAV-unit of senior, which arbitrage holds near 1.0
     *      inside [alpha, beta] — not the price of a raw share.
     */
    function _spotSTinQuoteWAD() internal view returns (uint256 px) {
        (IGyroECLPPool.EclpParams memory params, IGyroECLPPool.DerivedEclpParams memory derived) = GyroECLPPool(POOL).getECLPParams();
        uint256[] memory live = _liveBalances();
        uint256 invariant = IBasePool(POOL).computeInvariant(live, Rounding.ROUND_DOWN);
        px = GyroECLPMath.calcSpotPrice0in1(live, params, derived, int256(invariant));
        if (_stPoolIndex() == 1) px = Math.mulDiv(WAD, WAD, px);
    }

    /// @notice The E-CLP price band on the ST-in-quote price: [alpha, beta] as registered, inverted if ST is token1.
    function _stPriceBandWAD() internal view returns (uint256 lo, uint256 hi) {
        (IGyroECLPPool.EclpParams memory params,) = GyroECLPPool(POOL).getECLPParams();
        uint256 alpha = uint256(params.alpha);
        uint256 beta = uint256(params.beta);
        if (_stPoolIndex() == 0) return (alpha, beta);
        return (Math.mulDiv(WAD, WAD, beta), Math.mulDiv(WAD, WAD, alpha));
    }

    /// @notice Values a raw quote-asset amount in NAV units at the oracle's constant-1.0 feed mark.
    function _quoteToNAV(uint256 _quoteAssets) internal view returns (uint256) {
        return Math.mulDiv(_quoteAssets, WAD, _quoteScale());
    }

    /// @notice One whole quote token in raw units.
    function _quoteScale() internal view returns (uint256) {
        return 10 ** IERC20Metadata(testConfig.quoteAsset).decimals();
    }

    /// @notice Values ST shares in NAV units at an explicit rate (callers choose the cache regime of the rate they pass).
    function _stSharesToNAVAtRate(uint256 _shares, uint256 _rateWAD) internal pure returns (uint256) {
        return Math.mulDiv(_shares, _rateWAD, WAD);
    }

    /// @notice The kernel's senior-share rate (the pool rate provider). Cache regime is the caller's concern.
    function _kernelRate() internal view returns (uint256) {
        return BalancerV3_LT_BPTOracle_Quoter(address(KERNEL)).getRate();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CAPACITY PROBES + SKEW BUILDERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice The largest exact-in amount of `_tokenIn` the pool can absorb without reverting (range boundary,
     *         trade-size caps, or any other venue limit), found by geometric ramp then bisection of query probes.
     * @dev Every probe runs under a state snapshot, so nothing leaks. Deterministic at the pinned fork block.
     *      The floor starts at one minimum-trade unit in the token's raw decimals.
     */
    function _maxSwapInBeforeRangeRevert(address _tokenIn) internal returns (uint256 maxIn) {
        address tokenOut = _tokenIn == address(ST) ? testConfig.quoteAsset : address(ST);

        // Floor: both legs must clear the vault's scaled-18 minimum-trade size AND land a nonzero raw amount
        // on the coarser-decimal side (a min-trade-sized 18-dec input floors a 6-dec output to zero raw wei,
        // which the vault rejects as TradeAmountTooSmall on the calculated leg).
        uint256 inDecimals = IERC20Metadata(_tokenIn).decimals();
        uint256 outDecimals = IERC20Metadata(tokenOut).decimals();
        uint256 coarseDecimals = inDecimals < outDecimals ? inDecimals : outDecimals;
        uint256 floorScaled18 = Math.max(2 * VAULT.getMinimumTradeAmount(), 10 * 10 ** (18 - coarseDecimals));
        uint256 lo = Math.mulDiv(floorScaled18, 10 ** inDecimals, WAD) + 1;
        (bool okFloor,) = _querySwapExactIn(_tokenIn, tokenOut, lo);
        if (!okFloor) return 0;

        // Geometric ramp: double until the first failing size.
        uint256 hi = lo;
        for (uint256 i = 0; i < 96; ++i) {
            uint256 next = hi * 2;
            (bool ok,) = _querySwapExactIn(_tokenIn, tokenOut, next);
            if (!ok) {
                hi = next;
                break;
            }
            hi = next;
            lo = next;
        }
        if (lo == hi) fail("_maxSwapInBeforeRangeRevert: no failing swap size found within the ramp budget");

        // Bisect [lo (passes), hi (fails)] to ~0.1% precision.
        for (uint256 i = 0; i < 40 && hi - lo > lo / 1000 + 1; ++i) {
            uint256 mid = (lo + hi) / 2;
            (bool ok,) = _querySwapExactIn(_tokenIn, tokenOut, mid);
            if (ok) lo = mid;
            else hi = mid;
        }
        maxIn = lo;
    }

    /**
     * @notice Skews the pool by swapping `_fractionOfCapacityWAD` of the probed boundary capacity.
     * @dev `_pushSTPriceUp = true` swaps quote -> ST (the pool's ST leg depletes, its price rises toward the
     *      band's ceiling); `false` swaps ST -> quote (toward the floor). The band is asymmetric and the
     *      post-seed spot is wherever seeding left it, so capacity is always probed, never assumed. The
     *      swapper is a dedicated funded external actor.
     */
    function _skewPool(bool _pushSTPriceUp, uint256 _fractionOfCapacityWAD) internal returns (uint256 amountIn, uint256 amountOut) {
        address tokenIn = _pushSTPriceUp ? testConfig.quoteAsset : address(ST);
        address tokenOut = _pushSTPriceUp ? address(ST) : testConfig.quoteAsset;
        uint256 capacity = _maxSwapInBeforeRangeRevert(tokenIn);
        assertGt(capacity, 0, "skew: the pool has no swap capacity in the requested direction");
        amountIn = Math.mulDiv(capacity, _fractionOfCapacityWAD, WAD);
        uint256 minTradeRaw = Math.mulDiv(VAULT.getMinimumTradeAmount(), 10 ** IERC20Metadata(tokenIn).decimals(), WAD) + 1;
        assertGe(amountIn, minTradeRaw, "skew: the requested capacity fraction is below the vault's minimum trade size");

        address skewer = _makeExternalLP("POOL_SKEWER");
        if (tokenIn == address(ST)) _fundExternalLP(skewer, amountIn, 0);
        else _fundExternalLP(skewer, 0, amountIn);
        amountOut = _swapExactIn(skewer, tokenIn, tokenOut, amountIn, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LIQUIDITY-GATE DRIVER
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Enables the LT overlay with a `minLiquidity` that pins the committed liquidity utilization at
     *         `_targetUtilizationWAD` against the current real pool depth (the deployed market ships minLiquidity 0).
     * @dev Syncs first so the requirement derivation reads a fresh committed checkpoint.
     */
    function _driveLiquidityUtilizationTo(uint256 _targetUtilizationWAD) internal {
        _sync();
        _enableLTOverlay(0.1e18, 0.5e18, _minLiquidityForTargetUtilization(_targetUtilizationWAD));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DERIVED BOUNDS (each derivation stated where it is used)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Bounds the pool TVL growth from an exact-in swap of NAV value `_valueIn`.
     * @dev Derivation: an exact-in swap charges the static fee `f` on the input; the pool retains
     *      `f * (1 - agg)` of it (the aggregate share is skimmed for the protocol/creator). The retained fee
     *      sits in the INPUT token, and its marginal contribution to the oracle's invariant-based TVL is the
     *      token's internal marginal value against the 1.0 feed mark, which the price band confines to
     *      [alpha, 1/alpha] of its feed value (either leg can be the input, so the widest in-range re-mark in
     *      each direction applies). Hence `TVL growth ∈ [feeKept * alpha, feeKept / alpha]` plus tolerance.
     */
    function _swapFeeTVLBound(uint256 _valueIn) internal view returns (uint256 lo, uint256 hi) {
        uint256 feeKept = Math.mulDiv(_valueIn, _staticSwapFeePctWAD(), WAD);
        feeKept = Math.mulDiv(feeKept, WAD - _aggregateSwapFeePctWAD(), WAD);
        (uint256 alpha,) = _stPriceBandWAD();
        uint256 tol = 2 * toUint256(maxNAVDelta());
        uint256 discounted = Math.mulDiv(feeKept, alpha, WAD);
        lo = discounted > tol ? discounted - tol : 0;
        hi = Math.mulDiv(feeKept, WAD, alpha) + tol;
    }

    /**
     * @notice The expected value leak of a single-sided add of NAV value `_valueIn` (feed-mark basis), plus
     *         the slack band around it. Generic in the deposited token: `_wWAD` is the DEPOSITED token's value
     *         share of the pool and `_spot*` its internal price against the feed mark (for an ST-side add:
     *         `_stValueShareWAD()` and `_spotSTinQuoteWAD()`; for a quote-side add: the complements/inverse).
     * @dev Derivation (verified against the executed math on fork): Balancer charges the static fee `f` only
     *      on the NON-proportional portion of an unbalanced add — `(1 - w) * V` at deposited-token value share
     *      `w` — AND that imbalanced portion is absorbed at the pool's INTERNAL marginal price `q` (the
     *      pre-add spot), not the feed mark. Homogeneity of the E-CLP invariant gives the minted claim
     *      `V * (1 - (1 - w) * (f + (1 - q)))`, so:
     *
     *          expectedLeak = (1 - w) * V * (f + (1 - q))
     *
     *      SIGNED: with `q > 1 + f` the pool pays a premium for the token it is short of and the adder GAINS.
     *      Slack: the curve-walk trapezoid `|spotAfter - spotBefore| * V / 2`, one fee-of-V cushion for the
     *      protocol-skim/rounding stack, and the standard tolerance.
     */
    function _expectedSingleSidedAddLeak(
        uint256 _valueIn,
        uint256 _wWAD,
        uint256 _spotBeforeWAD,
        uint256 _spotAfterWAD
    )
        internal
        view
        returns (int256 expectedLeak, uint256 slack)
    {
        int256 feePlusDiscount = int256(_staticSwapFeePctWAD()) + (int256(WAD) - int256(_spotBeforeWAD));
        expectedLeak = int256(Math.mulDiv(_valueIn, WAD - _wWAD, WAD)) * feePlusDiscount / int256(WAD);
        uint256 spotDelta = _spotAfterWAD > _spotBeforeWAD ? _spotAfterWAD - _spotBeforeWAD : _spotBeforeWAD - _spotAfterWAD;
        slack = Math.mulDiv(_valueIn, spotDelta, 2 * WAD) + Math.mulDiv(_valueIn, _staticSwapFeePctWAD(), WAD) + 2 * toUint256(maxNAVDelta());
    }

    /**
     * @notice The in-range band tying the oracle TVL to the feed-price mark-to-market of actual balances.
     * @dev Derivation: the interior-branch TVL is the mark-to-market of the HYPOTHETICAL pool composition at
     *      the feed price ratio — the curve's minimum of (x + y) — so TVL never exceeds the actual-balance
     *      MtM. Re-marking each unit from the pool's internal price q in [alpha, beta] to the feed price 1.0
     *      moves its value by at most (1 - alpha), flooring TVL at `mtm * alpha`.
     */
    function _tvlMtMBand(uint256 _mtm) internal view returns (uint256 lo, uint256 hi) {
        (uint256 alpha,) = _stPriceBandWAD();
        lo = Math.mulDiv(_mtm, alpha, WAD);
        hi = _mtm;
    }

    /// @notice `2 * maxNAVDelta()`: the stacked tolerance wherever a raw-quote rounding (1 raw USDC wei == 1e12
    ///         NAV wei == `maxNAVDelta` exactly for the snUSD market) can combine with a NAV floor.
    function _tol2() internal view returns (uint256) {
        return 2 * toUint256(maxNAVDelta());
    }
}
