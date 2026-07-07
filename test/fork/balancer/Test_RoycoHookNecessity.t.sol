// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ILPOracleFactoryBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { IBasePool } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IBasePool.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";

import {
    AddLiquidityKind,
    AddLiquidityParams,
    RemoveLiquidityKind,
    RemoveLiquidityParams,
    SwapKind,
    VaultSwapParams
} from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";

import { ConstantPriceFeed } from "../../../lib/balancer-v3-monorepo/pkg/oracles/contracts/ConstantPriceFeed.sol";
import { LPOracleBase } from "../../../lib/balancer-v3-monorepo/pkg/oracles/contracts/LPOracleBase.sol";
import {
    AggregatorV3Interface as BalAggregatorV3Interface
} from "../../../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

import { ADMIN_ACCOUNTANT_ROLE, LT_LP_ROLE } from "../../../src/factory/RolesConfiguration.sol";

import { IRoycoLiquidityTranche } from "../../../src/interfaces/IRoycoLiquidityTranche.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { AggregatorV3Interface } from "../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";

import { WAD } from "../../../src/libraries/Constants.sol";
import { AssetClaims, MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";

import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { DeployScript } from "../../../script/Deploy.s.sol";
import { RoycoDayTestBase } from "../../utils/RoycoDayTestBase.sol";

/// @dev The senior-share rate provider surface the pool reads (the kernel implements `getRate`).
interface IStShareRate {
    function getRate() external view returns (uint256 rate);
}

/**
 * @title BalancerV3PoolActor
 * @notice A third-party actor that drives a Balancer V3 pool directly through the Vault (`unlock` -> op -> `settle`),
 *         the low-level path the Router itself uses. It is deliberately not the Royco kernel and not a Day contract, so
 *         its swaps and its liquidity provision are exactly the "external" pool activity the market's LT pool sees, with
 *         no Day operation to bracket it and no pre-operation sync before it.
 * @dev The settlement pattern (transfer-in-then-`settle` for debts, `sendTo` for credits) mirrors the kernel's own
 *      `BalancerV3VenueLogic`. It works for pool initialization too, which the prepaid-Router path does not cover.
 */
contract BalancerV3PoolActor {
    using SafeERC20 for IERC20;

    IVault public immutable VAULT;

    constructor(IVault _vault) {
        VAULT = _vault;
    }

    modifier onlyVault() {
        require(msg.sender == address(VAULT), "actor: only vault");
        _;
    }

    // Pool initialization (seeds the first liquidity; mints the initial BPT to this actor)
    function initialize(address _pool, IERC20[] calldata _tokens, uint256[] calldata _amounts, uint256 _minBptOut) external returns (uint256 bpt) {
        bytes memory ret = VAULT.unlock(abi.encodeCall(this.initializeCallback, (_pool, _tokens, _amounts, _minBptOut)));
        bpt = abi.decode(ret, (uint256));
    }

    function initializeCallback(
        address _pool,
        IERC20[] calldata _tokens,
        uint256[] calldata _amounts,
        uint256 _minBptOut
    )
        external
        onlyVault
        returns (uint256 bpt)
    {
        bpt = VAULT.initialize(_pool, address(this), _tokens, _amounts, _minBptOut, "");
        for (uint256 i; i < _tokens.length; ++i) {
            if (_amounts[i] != 0) {
                _tokens[i].safeTransfer(address(VAULT), _amounts[i]);
                VAULT.settle(_tokens[i], _amounts[i]);
            }
        }
    }

    // Unbalanced add (an external liquidity provider putting capital into the LT venue)
    function addUnbalanced(address _pool, uint256[] calldata _exactAmountsIn, uint256 _minBptOut) external returns (uint256 bpt) {
        bytes memory ret = VAULT.unlock(abi.encodeCall(this.addCallback, (_pool, _exactAmountsIn, _minBptOut)));
        bpt = abi.decode(ret, (uint256));
    }

    function addCallback(address _pool, uint256[] calldata _exactAmountsIn, uint256 _minBptOut) external onlyVault returns (uint256 bpt) {
        IERC20[] memory tokens = VAULT.getPoolTokens(_pool);
        uint256[] memory amountsIn;
        (amountsIn, bpt,) = VAULT.addLiquidity(
            AddLiquidityParams({
                pool: _pool, to: address(this), maxAmountsIn: _exactAmountsIn, minBptAmountOut: _minBptOut, kind: AddLiquidityKind.UNBALANCED, userData: ""
            })
        );
        for (uint256 i; i < tokens.length; ++i) {
            if (amountsIn[i] != 0) {
                tokens[i].safeTransfer(address(VAULT), amountsIn[i]);
                VAULT.settle(tokens[i], amountsIn[i]);
            }
        }
    }

    // Unbalanced remove (single token out, exact BPT in): an external LP pulling one leg out
    function removeSingleToken(address _pool, uint256 _bptIn, uint256 _tokenOutIndex, uint256 _minAmountOut) external returns (uint256 amountOut) {
        bytes memory ret = VAULT.unlock(abi.encodeCall(this.removeCallback, (_pool, _bptIn, _tokenOutIndex, _minAmountOut)));
        amountOut = abi.decode(ret, (uint256));
    }

    function removeCallback(address _pool, uint256 _bptIn, uint256 _tokenOutIndex, uint256 _minAmountOut) external onlyVault returns (uint256 amountOut) {
        IERC20[] memory tokens = VAULT.getPoolTokens(_pool);
        uint256[] memory minOut = new uint256[](tokens.length);
        // For SINGLE_TOKEN_EXACT_IN the Vault identifies the output token by the single non-zero minAmountsOut entry, so the
        // target index must be non-zero (all-zero reverts with AllZeroInputs). A 1-wei floor is a trivial slippage bound.
        minOut[_tokenOutIndex] = _minAmountOut == 0 ? 1 : _minAmountOut;
        (, uint256[] memory amountsOut,) = VAULT.removeLiquidity(
            RemoveLiquidityParams({
                pool: _pool, from: address(this), maxBptAmountIn: _bptIn, minAmountsOut: minOut, kind: RemoveLiquidityKind.SINGLE_TOKEN_EXACT_IN, userData: ""
            })
        );
        amountOut = amountsOut[_tokenOutIndex];
        if (amountOut != 0) VAULT.sendTo(tokens[_tokenOutIndex], address(this), amountOut);
    }

    // Exact-in swap (an external trader routing through the pool)
    function swapExactIn(address _pool, IERC20 _tokenIn, IERC20 _tokenOut, uint256 _amountIn) external returns (uint256 amountOut) {
        bytes memory ret = VAULT.unlock(abi.encodeCall(this.swapCallback, (_pool, _tokenIn, _tokenOut, _amountIn)));
        amountOut = abi.decode(ret, (uint256));
    }

    function swapCallback(address _pool, IERC20 _tokenIn, IERC20 _tokenOut, uint256 _amountIn) external onlyVault returns (uint256 amountOut) {
        (,, amountOut) = VAULT.swap(
            VaultSwapParams({
                kind: SwapKind.EXACT_IN, pool: _pool, tokenIn: _tokenIn, tokenOut: _tokenOut, amountGivenRaw: _amountIn, limitRaw: 0, userData: ""
            })
        );
        _tokenIn.safeTransfer(address(VAULT), _amountIn);
        VAULT.settle(_tokenIn, _amountIn);
        VAULT.sendTo(_tokenOut, address(this), amountOut);
    }
}

/**
 * @title RoycoHookNecessity
 * @notice Verifies directly that Royco Day's LT pool does not need a pool hook for the senior rate an external pool
 *         operation sees to be current, nor for Day's other reads (the LT mark `ltRawNAV`, the liquidity check, and the
 *         liquidity premium) to be correct.
 *
 * @dev Reuses the full `Neutrl_snUSD` fork market (mainnet fork, real Balancer V3 Vault + Gyro E-CLP factory + LP-oracle
 *      factory; nothing is mocked except the RedStone nUSD feed that the base already mocks to inject senior PnL). The pool
 *      the external actors touch is the market's own LT pool, which the deployment template creates with no hook
 *      (hooksContract == address(0)) and which names this kernel as its senior-leg rate provider. With no hook there is no
 *      pre-operation sync, so an external swap or third-party add/remove reads the kernel's `getRate` on its cache-miss
 *      (preview) path, exactly as a production external operation would.
 *
 * @dev The checkpoint that establishes the stale rate R0 is committed in `setUp`. This matters: the kernel caches the senior
 *      rate in EIP-1153 transient storage during a sync, and Foundry clears transient storage at the setUp->test boundary
 *      (verified separately) but not between calls inside a test. Committing in `setUp` therefore hands each test body an empty
 *      transient cache, exactly as a fresh production transaction would see, so `getRate()` in the body genuinely exercises the
 *      cache-miss (no-pre-op-sync) path rather than reading a value a same-transaction sync left behind.
 *
 * @dev This contract deliberately does not inherit the shared kernel test battery (`AbstractKernelTestSuite`, reached through
 *      `Neutrl_snUSD`): it runs under a seeded, hookless, overlay-on fixture that the fresh-deploy deposit/redeem/sync battery
 *      does not expect, so it stands alone on `BaseTest` and reuses the market deploy plus the family mechanics directly.
 */
contract RoycoHookNecessity is RoycoDayTestBase {
    using SafeERC20 for IERC20;

    /// @notice A liquidity overlay setting. It is always applied through the real setMinLiquidity / setMaxYieldShares in
    ///         setUp, never written straight to storage, so every configuration under test is one the setters accept.
    struct OverlayConfig {
        uint64 minLiq; // minimum secondary-liquidity requirement (setMinLiquidity requires minLiquidity < WAD)
        uint64 maxJt; // maximum junior risk premium (setMaxYieldShares requires maxJt + maxLt <= WAD)
        uint64 maxLt; // maximum liquidity-tranche premium
    }

    /// @dev The overlay this contract applies in setUp. The shipped snUSD market ships the LT service off ("Dawn baseline");
    ///      this default is a low, valid setting: 5% minimum liquidity, a 30% liquidity premium, a 50% junior premium. The
    ///      overlay-variant subclasses at the end of this file override it to cover the parameter space; setUp applies
    ///      whatever it returns, so the fuzz below runs once per overlay.
    function _overlayConfig() internal pure virtual returns (OverlayConfig memory) {
        return OverlayConfig({ minLiq: 0.05e18, maxJt: 0.5e18, maxLt: 0.3e18 });
    }

    uint256 internal constant ST_TRANCHE_SEED = 200_000e18; // snUSD deposited into the senior tranche
    uint256 internal constant JT_TRANCHE_SEED = 200_000e18; // snUSD deposited into the junior tranche (coverage)
    uint256 internal constant ST_SHARES_FOR_SEED_ACTOR = 120_000e18; // senior shares handed to the seed actor for pool inits
    uint256 internal constant POOL_INIT_ST_SHARES = 30_000e18; // senior-leg size of each pool's initial liquidity
    uint256 internal constant LT_SEED_ST_ASSETS = 15_000e18; // snUSD routed into the LT tranche (raises ltRawNAV)
    uint256 internal constant LT_SEED_QUOTE = 15_000e6; // USDC routed into the LT tranche

    address internal ST_SHARE; // senior tranche share token (a pool leg + the priced/rate-scaled leg)
    address internal QUOTE; // USDC (the pool's other leg)

    BalancerV3PoolActor internal seedActor; // seeds the LT pool's first liquidity; its BPT is the reference holding for the mark
    BalancerV3PoolActor internal alice; // external LP + trader
    BalancerV3PoolActor internal bob; // second external LP
    address internal ltHolder; // the Day LT-share holder used for the "Day redeems" leg

    // The pool the external actors touch is the market's own LT pool, `POOL` (== `KERNEL.LT_ASSET()`), which the template
    // creates with no hook. `poolOracle` is an E-CLP LP oracle the test deploys over it (the same oracle family the kernel
    // uses for ltRawNAV) so the mark test reads a real oracle rather than pool spot.
    address internal poolOracle;
    uint256 internal stIndex; // senior-leg index in the LT pool's token registration order
    uint256 internal quoteIndex; // quote-leg index in the LT pool's token registration order

    // Committed-at-M0 anchors captured in setUp (the "stale checkpoint" a hook would have refreshed).
    uint256 internal R0; // senior rate committed at M0
    uint256 internal ltRawNAV_M0; // kernel LT mark committed at M0
    uint256 internal refBpt; // seed actor's LT-pool BPT balance (the fixed reference holding for the mark)
    uint256 internal refMark_M0; // LT-pool oracle mark of that fixed holding at M0

    // Market wiring duplicated from the Neutrl_snUSD fixture (this contract stands alone; see the contract note)
    address internal constant SNUSD_VAULT = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313; // ST/JT ERC4626 asset
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // LT pool quote asset
    address internal constant NUSD_REDSTONE_ORACLE = 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95; // base(nUSD)->NAV feed

    IVault internal VAULT; // the Balancer V3 Vault the LT pool is registered with
    IRoycoVaultTranche internal LT; // the liquidity tranche (holds the BPT)
    address internal POOL; // the market's LT pool (== KERNEL.LT_ASSET()), created with no hook

    // The base->NAV feed answer, mocked once at its live value then moved by simulate*, re-stamped fresh on each apply.
    int256 internal _mockedOracleAnswer;
    bool internal _oracleMocked;

    // ===========================================================================
    // Setup: reuse the full fork market, seed the LT pool + tranche, enable the LT service, commit M0
    // ===========================================================================

    function setUp() public virtual {
        // Stand-alone deploy of the same Neutrl snUSD fork market the shared fixtures use, without inheriting their test
        // battery. Skip the whole suite when MAINNET_RPC_URL is unset, exactly as the shared base does.
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 25_400_000);

        _setupWallets();
        DEPLOY_SCRIPT = new DeployScript();
        _buildMarket();
    }

    /**
     * @notice Deploys and seeds one fresh Neutrl snUSD market to the M0 baseline (deploy, capture LT topology, fund and seed
     *         the senior/junior tranches, initialize and seed the LT pool, enable the overlay, pin the feed, commit M0).
     * @dev Called by setUp and, again, by the premium-cadence tests to rebuild an independent market for the second schedule,
     *      because snapshot-and-restore is unreliable across repeated cycles on this fork (see the cadence section note). Each
     *      call redeploys, so it overwrites the member vars with the new market's contracts and a fresh set of providers.
     */
    function _buildMarket() internal {
        _setDeployedMarket(_deployMarket());

        // Capture the LT topology the deployment result omits (the shared LT fixture does the same read).
        LT = IRoycoVaultTranche(KERNEL.LIQUIDITY_TRANCHE());
        POOL = KERNEL.LT_ASSET();
        VAULT = IVault(address(GyroECLPPoolFactory(DEPLOY_SCRIPT.getChainConfig(block.chainid).gyroECLPPoolFactory).getVault()));
        vm.label(address(LT), "LT");
        vm.label(POOL, "BalancerPool");

        // Providers get their ST/JT LP roles here (after the deploy that seats the LP-role admin); then the two seeders fund.
        _setupProviders();
        deal(SNUSD_VAULT, ST_ALICE_ADDRESS, 1_000_000e18);
        deal(SNUSD_VAULT, JT_ALICE_ADDRESS, 1_000_000e18);

        ST_SHARE = KERNEL.SENIOR_TRANCHE();
        QUOTE = KERNEL.QUOTE_ASSET();

        _seedSeniorAndJunior();
        // A tranche deposit runs a pre-op sync; the senior deposit's pre-op sync ran while senior supply was still zero, so it
        // cached ST_SHARE_RATE == 1 (the zero-supply floor). Foundry keeps transient storage across calls within this one setUp
        // transaction, so that stale 1 would misprice the LT pool the actors initialize below. A fresh sync at the real supply
        // rewrites the cache to the true rate. (In production each op is its own transaction, so the cache is never stale here.)
        _syncCommit();
        _buildActors();
        _seedLtPoolAndTranche();
        _enableLtService();
        _deployPoolOracle();

        // Freeze the senior feed at its live value (a 0% move) so the M0 checkpoint marks a fresh, known oracle, and a later
        // warp can re-stamp it without re-reading a by-then-stale real feed.
        _pinOracleFresh();

        // Commit the checkpoint at M0 and record the anchors the tests compare against.
        _syncCommit();
        R0 = _rate();
        ltRawNAV_M0 = toUint256(LT.getRawNAV());
        refBpt = IERC20(POOL).balanceOf(address(seedActor));
        refMark_M0 = _poolMark(refBpt);
    }

    // ===========================================================================
    // Test 1: with no hook, external swaps and external LPs see the current senior rate
    // ===========================================================================

    /**
     * The core property. After a real gap opens between the last committed rate (R0) and the true current rate (R1), a
     * third party swaps, adds, and removes on the market's LT pool. With no hook there is no pre-op sync, so the pool reads
     * the kernel's `getRate()` on its cache-MISS path. We assert that value is R1 (a fresh preview of the current marks),
     * equals what an actual fresh sync commits, and is not the stale R0, and that every external operation succeeds.
     */
    function test_noHook_externalOps_seeCurrentRate() external {
        if (address(KERNEL) == address(0)) return;

        // 1. Open the gap: advance time and move the senior value, with NO Day operation, so the committed checkpoint still
        //    holds R0 while the true current rate has moved to R1.
        vm.warp(block.timestamp + 1 days);
        simulateSTYield(0.02e18); // +2% senior net asset value

        // 2. The rate a hookless pool operation reads (cache miss, previews the current marks).
        uint256 R1 = _rate();
        assertGt(R1, R0, "R1 must have moved above the stale R0");

        // 3. External activity on the market's LT pool: a swap, an unbalanced add, an unbalanced remove. None is a Day operation.
        uint256 swapOut = alice.swapExactIn(POOL, IERC20(QUOTE), IERC20(ST_SHARE), 1000e6);
        assertGt(swapOut, 0, "external swap must fulfil");
        uint256 aliceBpt = alice.addUnbalanced(POOL, _quoteOnly(2000e6, stIndex, quoteIndex), 0);
        assertGt(aliceBpt, 0, "external unbalanced add must mint BPT");
        uint256 bobBpt = bob.addUnbalanced(POOL, _quoteOnly(3000e6, stIndex, quoteIndex), 0);
        assertGt(bobBpt, 0, "second external LP add must mint BPT");
        uint256 removed = alice.removeSingleToken(POOL, aliceBpt / 2, quoteIndex, 0);
        assertGt(removed, 0, "external unbalanced remove must return the quote leg");

        // 4a. The rate the pool used is unchanged by the external activity (no sync ran) and is still the current R1.
        assertEq(_rate(), R1, "rate stayed current across external ops (no stale read, no hook)");

        // 4b. Ground truth: an actual fresh sync now commits exactly R1. This is the value a hook would have produced.
        SyncedAccountingState memory synced = _syncCommit();
        uint256 committedRate = _rate(); // cache hit after the sync == the committed post-sync rate
        assertEq(committedRate, R1, "no-hook cache-miss rate == the rate a fresh sync commits");
        assertTrue(R1 != R0, "the committed R0 and the current R1 differ: the gap is real");

        // 4c. Independent sanity: the committed rate equals senior effective NAV per share (floored), not routed through getRate.
        uint256 independentRate = Math.mulDiv(toUint256(ST.totalAssets().nav), WAD, IERC20(ST_SHARE).totalSupply(), Math.Rounding.Floor);
        assertApproxEqAbs(R1, independentRate, 2, "rate == floor(stEffectiveNAV * WAD / stSupply)");

        // Record for the report.
        emit log_named_uint("R0 (committed, stale)", R0);
        emit log_named_uint("R1 (current, no-hook)", R1);
        assertEq(uint8(synced.marketState), uint8(MarketState.PERPETUAL), "market perpetual");
    }

    // ===========================================================================
    // Test 2: the LT mark, the liquidity check, the premium, and a Day redeem are all correct with no hook
    // ===========================================================================

    function test_noHook_otherReads_markCheckPremiumRedeem() external virtual {
        if (address(KERNEL) == address(0)) return;

        // Open the same gap (time + senior value), no Day operation.
        vm.warp(block.timestamp + 1 days);
        simulateSTYield(0.02e18);

        // 5a. The LT mark (ltRawNAV) is a live oracle read, needs no sync/hook, and moved only because the senior rate moved.
        //     A third party's own adds/removes/swaps on the pool do not move the value of the BPT the kernel holds.
        uint256 markBeforeExternal = _poolMark(refBpt);
        alice.swapExactIn(POOL, IERC20(QUOTE), IERC20(ST_SHARE), 1000e6);
        alice.addUnbalanced(POOL, _quoteOnly(2000e6, stIndex, quoteIndex), 0);
        uint256 markAfterExternal = _poolMark(refBpt);
        assertApproxEqRel(markAfterExternal, markBeforeExternal, 0.001e18, "BPT-oracle mark invariant to third-party pool activity (<=0.1%)");
        assertGt(markAfterExternal, refMark_M0, "the mark moved with the senior rate, not with the external activity");

        // The kernel's own ltRawNAV likewise moved up with the rate; it is a committed-checkpoint-independent
        // live read, so it is correct with or without a hook.
        uint256 ltRawNAV_M1 = toUint256(LT.getRawNAV());
        assertGt(ltRawNAV_M1, ltRawNAV_M0, "kernel ltRawNAV moved up with the senior rate");

        // 5b. The liquidity check evaluates correctly. previewSyncTrancheAccounting is a rate-only view (it takes no LT mark),
        //     so the liquidity check's liquidityUtilization is resolved by an actual sync, which reads the fresh BPT-oracle mark and
        //     commits it. Recompute it independently: liquidityUtilization = ceil(stEffectiveNAV * minLiquidity / ltRawNAV).
        SyncedAccountingState memory synced = _syncCommit();
        uint256 stEff = toUint256(synced.stEffectiveNAV);
        uint256 ltRaw = toUint256(synced.ltRawNAV);
        uint256 expectedUtil = ltRaw == 0 ? type(uint256).max : Math.mulDiv(stEff, _overlayConfig().minLiq, ltRaw, Math.Rounding.Ceil);
        assertEq(synced.liquidityUtilizationWAD, expectedUtil, "liquidityUtilization == ceil(stEff * minLiquidity / ltRawNAV)");
        assertLe(synced.liquidityUtilizationWAD, WAD, "liquidity healthy: redemptions enabled");
        emit log_named_uint("liquidityUtilizationWAD (no-hook run)", synced.liquidityUtilizationWAD);
        emit log_named_uint("ltRawNAV at M1", ltRaw);

        // 5c. Day itself redeems from the LT and settles at exactly its preview (the redeemer receives the in-kind BPT slice).
        uint256 ltShares = IERC20(address(LT)).balanceOf(ltHolder);
        assertGt(ltShares, 0, "LT holder seeded");
        uint256 redeemShares = ltShares / 4;
        AssetClaims memory previewClaim = KERNEL.ltPreviewRedeem(redeemShares);
        uint256 bptBefore = IERC20(KERNEL.LT_ASSET()).balanceOf(ltHolder);
        vm.prank(ltHolder);
        AssetClaims memory got = LT.redeem(redeemShares, ltHolder, ltHolder);
        assertEq(toUint256(got.ltAssets), toUint256(previewClaim.ltAssets), "LT redeem settled at its preview (BPT out)");
        assertEq(IERC20(KERNEL.LT_ASSET()).balanceOf(ltHolder) - bptBefore, toUint256(got.ltAssets), "redeemer received the BPT slice in kind");

        // 6. The premium accrues correctly on Day's next operation, over the elapsed window, from the committed checkpoint,
        //    without any hook-driven interim sync. The returned sync state carries the premium minted this sync.
        vm.warp(block.timestamp + 7 days);
        simulateSTYield(0.01e18); // further senior yield over the window
        uint256 ltOwnedBefore = KERNEL.getState().ltOwnedSeniorTrancheShares + toUint256(LT.getRawNAV());
        SyncedAccountingState memory premiumSync = _syncCommit();
        assertGt(toUint256(premiumSync.ltLiquidityPremium), 0, "liquidity premium accrued over the elapsed window");
        emit log_named_uint("ltLiquidityPremium accrued (NAV units)", toUint256(premiumSync.ltLiquidityPremium));
        uint256 ltOwnedAfter = KERNEL.getState().ltOwnedSeniorTrancheShares + toUint256(LT.getRawNAV());
        assertGt(ltOwnedAfter, ltOwnedBefore, "premium increased the LT's senior-share/BPT holdings");
        assertEq(ACCOUNTANT.getState().lastPremiumPaymentTimestamp, uint32(block.timestamp), "premium payment timestamp advanced to now");
    }

    // ===========================================================================
    // Setup helpers
    // ===========================================================================

    function _seedSeniorAndJunior() internal {
        // Give the junior tranche first-loss coverage first, then the senior tranche its supply: a senior deposit is
        // checked against coverage, so it must be made against existing junior coverage. ST_ALICE / JT_ALICE hold the required LP roles
        // and were funded with snUSD by the base.
        _depositJT(JT_ALICE_ADDRESS, JT_TRANCHE_SEED);
        _depositST(ST_ALICE_ADDRESS, ST_TRANCHE_SEED + ST_SHARES_FOR_SEED_ACTOR); // extra snUSD -> senior shares for pool inits
    }

    function _buildActors() internal {
        seedActor = new BalancerV3PoolActor(VAULT);
        alice = new BalancerV3PoolActor(VAULT);
        bob = new BalancerV3PoolActor(VAULT);
        vm.label(address(seedActor), "SeedActor");
        vm.label(address(alice), "ExternalLP_Alice");
        vm.label(address(bob), "ExternalLP_Bob");

        // Hand the seed actor the senior shares it needs to initialize the LT pool; give every actor quote (USDC).
        vm.prank(ST_ALICE_ADDRESS);
        IERC20(ST_SHARE).safeTransfer(address(seedActor), ST_SHARES_FOR_SEED_ACTOR);
        deal(QUOTE, address(seedActor), 200_000e6);
        deal(QUOTE, address(alice), 200_000e6);
        deal(QUOTE, address(bob), 200_000e6);
    }

    function _seedLtPoolAndTranche() internal {
        (stIndex, quoteIndex) = _legIndexes(POOL);

        // Initialize the LT pool (Balancer V3 requires an explicit first-liquidity seed; the deploy script does not do it).
        // The pool has no hook, so pool initialization runs no sync.
        _initializePoolValueBalanced(POOL, stIndex, quoteIndex, POOL_INIT_ST_SHARES);

        // Route capital into the LT tranche so the kernel holds BPT and ltRawNAV > 0. depositMultiAsset is PUBLIC-role; the
        // LT holder redeems later so it also needs LT_LP_ROLE.
        ltHolder = ST_BOB_ADDRESS;
        vm.prank(LP_ROLE_ADMIN_ADDRESS);
        ACCESS_MANAGER.grantRole(LT_LP_ROLE, ltHolder, 0);
        deal(KERNEL.ST_ASSET(), ltHolder, LT_SEED_ST_ASSETS);
        deal(QUOTE, ltHolder, LT_SEED_QUOTE);
        vm.startPrank(ltHolder);
        IERC20(KERNEL.ST_ASSET()).forceApprove(address(LT), LT_SEED_ST_ASSETS);
        IERC20(QUOTE).forceApprove(address(LT), LT_SEED_QUOTE);
        IRoycoLiquidityTranche(address(LT)).depositMultiAsset(LT_SEED_ST_ASSETS, LT_SEED_QUOTE, 1, ltHolder);
        vm.stopPrank();
    }

    function _enableLtService() internal {
        // Apply this test's overlay through the REAL accountant setters, so it is valid by construction: the setters enforce
        // minLiquidity < WAD and maxJT + maxLT <= WAD. The deployed ADMIN_ACCOUNTANT_ROLE holder carries a non-zero execution
        // delay (scheduled ops), so grant the role to this test contract with zero delay from the AccessManager admin and call
        // the setters directly. This runs in setUp, before the setUp->body boundary that clears the transient rate cache, so
        // the setters' own withSyncedAccounting sync does not leave the cache populated for the test body.
        OverlayConfig memory o = _overlayConfig();
        vm.prank(OWNER_ADDRESS);
        ACCESS_MANAGER.grantRole(ADMIN_ACCOUNTANT_ROLE, address(this), 0);
        ACCOUNTANT.setMaxYieldShares(o.maxJt, o.maxLt);
        ACCOUNTANT.setMinLiquidity(o.minLiq);
    }

    function _deployPoolOracle() internal {
        // The same manipulation-resistant E-CLP LP oracle family the kernel uses for ltRawNAV, deployed over the market's LT
        // pool, so the mark test reads a real oracle rather than pool spot. Each leg's live balance is priced by its rate
        // provider, so the residual per-leg feed is a constant 1.0.
        ConstantPriceFeed feed = new ConstantPriceFeed();
        IERC20[] memory tokens = VAULT.getPoolTokens(POOL);
        BalAggregatorV3Interface[] memory feeds = new BalAggregatorV3Interface[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            feeds[i] = BalAggregatorV3Interface(address(feed));
        }
        poolOracle = address(
            ILPOracleFactoryBase(DEPLOY_SCRIPT.getChainConfig(block.chainid).eclpLPOracleFactory)
                .create({ pool: IBasePool(POOL), shouldUseBlockTimeForOldestFeedUpdate: false, shouldRevertIfVaultUnlocked: false, feeds: feeds })
        );
    }

    /// @dev Initializes a pool with value-balanced amounts (rate-scaled senior value == quote value), which sits at the
    ///      E-CLP peg (price ~ 1.0) and so within [alpha, beta]. Quote is sized from the live senior rate.
    function _initializePoolValueBalanced(address _pool, uint256 _stIndex, uint256 _quoteIndex, uint256 _stShares) internal {
        uint256 rate = _rate(); // NAV per WAD senior share
        // value(senior) = _stShares * rate / WAD (18-dec NAV); quote is 6-dec USDC of equal value => divide by 1e12.
        uint256 quoteAmount = Math.mulDiv(_stShares, rate, WAD) / 1e12;

        IERC20[] memory tokens = VAULT.getPoolTokens(_pool);
        uint256[] memory amounts = new uint256[](2);
        amounts[_stIndex] = _stShares;
        amounts[_quoteIndex] = quoteAmount;

        // The seed actor already holds the senior shares (from _buildActors) and the quote (dealt); it transfers them into
        // the Vault and settles inside its unlock callback, so no ERC20 approvals are required here.
        seedActor.initialize(_pool, tokens, amounts, 0);
    }

    // ===========================================================================
    // Stand-alone harness: the deploy entry point + the family mechanics, duplicated from the shared fixtures so this
    // contract can reuse them WITHOUT inheriting the shared test battery (see the contract note)
    // ===========================================================================

    /// @dev The same deploy call the Neutrl_snUSD fixture makes: the snUSD market config and this test's role assignments.
    function _deployMarket() internal returns (DeployScript.DeploymentResult memory) {
        return DEPLOY_SCRIPT.deploy(
            DEPLOY_SCRIPT.getMarketConfig("snUSD"),
            OWNER_ADDRESS,
            PROTOCOL_FEE_RECIPIENT_ADDRESS,
            DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds,
            _generateRoleAssignments(),
            DEPLOYER.privateKey
        );
    }

    /// @dev Deposits `_amount` (snUSD asset units) from `_lp` into the senior tranche.
    function _depositST(address _lp, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_lp);
        IERC20(SNUSD_VAULT).approve(address(ST), _amount);
        shares = ST.deposit(toTrancheUnits(_amount), _lp);
        vm.stopPrank();
    }

    /// @dev Deposits `_amount` (snUSD asset units) from `_lp` into the junior tranche.
    function _depositJT(address _lp, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_lp);
        IERC20(SNUSD_VAULT).approve(address(JT), _amount);
        shares = JT.deposit(toTrancheUnits(_amount), _lp);
        vm.stopPrank();
    }

    /// @dev The base(nUSD)->NAV feed backing this market (the RedStone nUSD feed).
    function _baseAssetToNavOracle() internal pure returns (address) {
        return NUSD_REDSTONE_ORACLE;
    }

    /// @dev Injects senior yield by moving the mocked base->NAV feed up (ST and JT share the feed on this coinvested market).
    function simulateSTYield(uint256 _percentageWAD) internal {
        _moveOracle(int256(1), _percentageWAD);
    }

    /// @dev Injects a senior loss by moving the mocked base->NAV feed down.
    function simulateSTLoss(uint256 _percentageWAD) internal {
        _moveOracle(int256(-1), _percentageWAD);
    }

    /// @dev Freeze the feed's live value into the mock (a 0% move) so a later warp re-stamps it fresh without a stale read.
    function _pinOracleFresh() internal {
        _moveOracle(int256(1), 0);
    }

    /// @dev Move the base->NAV feed by `_percentageWAD` in the `_sign` direction, seeding the mock from the live feed once.
    function _moveOracle(int256 _sign, uint256 _percentageWAD) internal {
        address oracle = _baseAssetToNavOracle();
        if (!_oracleMocked) {
            (, int256 answer,,,) = AggregatorV3Interface(oracle).latestRoundData();
            _mockedOracleAnswer = answer;
            _oracleMocked = true;
        }
        _mockedOracleAnswer += _sign * ((_mockedOracleAnswer * int256(_percentageWAD)) / int256(1e18));
        _applyOracleMock(oracle);
    }

    /// @dev Stamp the mocked feed answer at the current block time, so the kernel's staleness check keeps passing.
    function _applyOracleMock(address _oracle) internal {
        vm.mockCall(
            _oracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), _mockedOracleAnswer, block.timestamp, block.timestamp, uint80(1))
        );
    }

    // ===========================================================================
    // Small helpers
    // ===========================================================================

    function _rate() internal view returns (uint256) {
        return IStShareRate(address(KERNEL)).getRate();
    }

    function _syncCommit() internal returns (SyncedAccountingState memory state) {
        vm.prank(SYNC_ROLE_ADDRESS);
        state = KERNEL.syncTrancheAccounting();
    }

    function _legIndexes(address _pool) internal view returns (uint256 stIndex, uint256 quoteIndex) {
        IERC20[] memory tokens = VAULT.getPoolTokens(_pool);
        (stIndex, quoteIndex) = address(tokens[0]) == ST_SHARE ? (0, 1) : (1, 0);
    }

    function _quoteOnly(uint256 _quoteAmount, uint256 _stIndex, uint256 _quoteIndex) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[_stIndex] = 0;
        amounts[_quoteIndex] = _quoteAmount;
    }

    function _poolMark(uint256 _bpt) internal view returns (uint256) {
        uint256 tvl = LPOracleBase(poolOracle).computeTVL();
        uint256 supply = VAULT.totalSupply(POOL);
        return supply == 0 ? 0 : Math.mulDiv(tvl, _bpt, supply);
    }

    // ===========================================================================
    // Fuzz: the getRate cache-miss / cache-hit equivalence across the state space
    // ===========================================================================

    /**
     * Regression guard for the single-scenario result above. At every fuzzed state, the senior rate getRate returns on a
     * cache miss (the path a hookless external pool operation takes, with no kernel sync earlier in the transaction) equals
     * the rate a fresh sync commits at that state, and equals the direct recomputation, the floor of the senior effective
     * net asset value times one whole share over the post-mint senior supply. So the value getRate returns on a cache hit
     * and the value it returns on a cache miss agree across the whole state space, not only at the one 2% scenario.
     *
     * Fuzzed continuously: the senior feed move (over gains and losses) and the elapsed time before the read. These are the
     * two inputs the share-rate arithmetic varies over that need no sync to apply. The liquidity overlay is not fuzzed in the
     * body: it is applied once in setUp through the real setMinLiquidity / setMaxYieldShares (see _overlayConfig), so each
     * configuration is valid by construction, and the overlay dimension is covered by the discrete variants at the end of this
     * file, each a separate test with its own setUp.
     */
    function testFuzz_getRate_cacheMissEqualsCommitAndRecompute(int256 _feedBps, uint256 _elapsed) external {
        if (address(KERNEL) == address(0)) return; // fork skipped when MAINNET_RPC_URL is unset

        // Bound the two continuously-fuzzed inputs. Neither passes through a setter, so both are valid across their whole
        // range: the feed move is a mock update and the elapsed time is a warp.
        _feedBps = bound(_feedBps, -5000, 5000); // -50% .. +50%, both gains and losses
        _elapsed = bound(_elapsed, 1, 4 weeks); // seconds .. weeks

        // Foundry reverts to the post-setUp state and clears the transient cache between fuzz runs (verified separately with a
        // standalone probe), so each run starts with an empty senior-rate cache and the setter-applied overlay already in
        // place. Re-apply the starting senior feed first, so a mock a prior run left behind does not carry over, then assert
        // getRate previews to the setUp-committed R0. That confirms the cache is empty: a genuine miss returns the previewed
        // committed value, not a stale cached one. getRate on a miss is a view that does not write the cache, so this read
        // does not itself dirty it.
        _pinOracleFresh();
        assertEq(_rate(), R0, "fuzz run did not start from an empty senior-rate cache");

        // Open a real gap between the committed checkpoint (still M0) and the current marks: advance time and move the feed.
        // No Day operation runs, so nothing syncs and the cache stays empty.
        vm.warp(block.timestamp + _elapsed);
        if (_feedBps >= 0) simulateSTYield(uint256(_feedBps) * 1e14); // 1 basis point == 1e14 in WAD
        else simulateSTLoss(uint256(-_feedBps) * 1e14);

        // The value a hookless external operation reads: getRate on the cache-miss (preview) path at the current state.
        uint256 missRate = _rate();

        // The value a fresh sync commits at the same state, then read back on a cache hit.
        SyncedAccountingState memory synced = _syncCommit();
        uint256 commitRate = _rate();

        // The direct recomputation, not routed through getRate: floor(senior effective NAV * one whole share / supply).
        uint256 recompute = Math.mulDiv(toUint256(ST.totalAssets().nav), WAD, IERC20(ST_SHARE).totalSupply(), Math.Rounding.Floor);
        // getRate floors the senior rate to a minimum of 1 wei, so mirror that for the degenerate near-zero case.
        if (recompute == 0) recompute = 1;

        // The equivalence at this fuzzed state: the preview path, the commit path, and the direct recomputation all agree.
        assertEq(missRate, commitRate, "cache-miss getRate != committed sync rate");
        assertEq(missRate, recompute, "cache-miss getRate != direct recomputation");
        assertTrue(synced.marketState == MarketState.PERPETUAL || synced.marketState == MarketState.FIXED_TERM, "defined market state");
    }

    // ===========================================================================
    // Premium conservation across sync cadence
    //
    // Without the hook, a P&L sync (which stages the liquidity premium) runs only when Day operates, not on every external
    // pool op, so staging is less frequent. These tests measure whether the total premium staged over a fixed window depends
    // on how often the sync runs. Both schedules are hookless and share the same senior-yield path (the same per-step feed
    // moves at the same times); they differ only in how often a Day sync runs. frequent syncs every step; infrequent injects
    // the same steps but syncs once at the end.
    //
    // Result 1 (the guard): the premium the sync sets aside is conserved to the wei. Result 2 (a reported finding): in the
    // market as shipped the premium delivered after reinvestment differs by a small bounded amount, infrequent higher.
    //
    // A note on harness shape. The (steps, window) points are per-method parameters, not fuzzer inputs. Foundry's fuzzer
    // reverts to the post-setUp state between runs, and on this fork that revert does not cleanly restore the Balancer pool
    // the reinvestment mutates: verified, the same input conserves when run once from a fresh deploy but the reading diverges
    // by the third fuzz run or the third sequential schedule (the frequent total collapses). One schedule from one fresh
    // deploy is exact, and a single snapshot restore per deploy is reliable; the sweep across methods (each its own fresh
    // setUp) covers the hours-to-weeks, few-to-many range that a fuzz would.
    // ===========================================================================

    uint256 internal constant CADENCE_TOTAL_YIELD_WAD = 0.01e18; // ~1% senior gain spread across the window in both schedules
    uint64 internal constant CADENCE_LT_SHARE_CAP = 0.05e18; // a low LT cap the LDM output clears at every utilization the window traverses, so the accrued LT share is constant

    // Result 1: the staged premium (the mint) is conserved across sync cadence to the wei

    function test_stagedPremium_conserved_shortWindow_fewSteps() external {
        _assertStagedPremiumConserved(2, 6 hours);
    }

    function test_stagedPremium_conserved_oneDay_eightSteps() external {
        _assertStagedPremiumConserved(8, 1 days);
    }

    function test_stagedPremium_conserved_medWindow_medSteps() external {
        _assertStagedPremiumConserved(16, 7 days);
    }

    function test_stagedPremium_conserved_shortWindow_manySteps() external {
        _assertStagedPremiumConserved(48, 40 hours);
    }

    function test_stagedPremium_conserved_medWindow_manySteps() external {
        _assertStagedPremiumConserved(32, 5 days);
    }

    /**
     * @notice The premium a sync sets aside (the mint) is conserved across sync frequency: over a fixed window and senior
     *         gain, the many small syncs of a frequent schedule stage in total exactly what a single sync stages over the
     *         same gain. This is the staging arithmetic itself; it neither loses nor invents premium as cadence changes.
     * @dev A single forward pass (no snapshot): staging every step, the cumulative premium is compared to
     *      `floor(totalSeniorGain * cap)`, which is exactly what one sync over that gain stages (verified equal to a real
     *      single sync). Two committed-state feedbacks are removed so the premium is a fixed fraction of the senior gain and
     *      only the staging arithmetic varies with cadence: the LT yield share is pinned at its cap (so the LDM's response to
     *      liquidity utilization, which reinvestment moves, cannot vary the share), and the JT risk premium is zeroed (so its
     *      tracking of coverage utilization cannot vary how much senior gain remains as the LT premium base, which also makes
     *      the senior effective NAV grow by exactly the gain each sync, so its growth is a clean measure of the total gain).
     */
    function _assertStagedPremiumConserved(uint256 _steps, uint256 _windowSecs) internal {
        if (address(KERNEL) == address(0)) return; // fork skipped when MAINNET_RPC_URL is unset
        // Skip the "Dawn baseline" overlay (LT service off: no minimum liquidity, no premium), where there is no staging to
        // measure. The premium-cadence property is exercised under the live low overlay and the near-caps overlay.
        if (_overlayConfig().maxLt == 0) return vm.skip(true);

        _setYieldShares(0, CADENCE_LT_SHARE_CAP);
        _pinOracleFresh();

        uint256 effStart = toUint256(ACCOUNTANT.getState().lastSTEffectiveNAV);
        uint256 frequentTotal = _stagedPremiumOverWindow(_steps, _windowSecs, true);
        uint256 totalSeniorGain = toUint256(ACCOUNTANT.getState().lastSTEffectiveNAV) - effStart;

        // What one sync stages over the same total gain: a single floored fraction. Frequent staging must sum to the same.
        uint256 oneSyncStages = Math.mulDiv(totalSeniorGain, CADENCE_LT_SHARE_CAP, WAD, Math.Rounding.Floor);
        assertGt(frequentTotal, 0, "arrange: a premium must accrue for the comparison to be meaningful");
        assertEq(frequentTotal, oneSyncStages, "the staged premium must be conserved across sync cadence to the wei");
    }

    // Result 2: the delivered premium in the market as shipped differs across cadence by a small bounded amount

    /**
     * @notice In the market as shipped (the overlay's own premium caps, the LT share floating, reinvestment as configured),
     *         the total premium delivered over a window depends mildly on sync frequency: fewer syncs deliver at least as
     *         much, by a small bounded amount. This is a reported finding, guarded only by a bound, not an equality.
     * @dev The dependence is real and expected: syncing tracks the committed checkpoint, so a less frequent schedule prices
     *      more of the window at the start-of-window yield shares. Two committed-state feedbacks drive it, both present with
     *      or without the hook: the JT risk premium tracks coverage utilization (changing how much senior gain remains as the
     *      LT premium base), and the LT liquidity premium's reinvestment raises the LT mark, which lowers liquidity
     *      utilization, which lowers later LT yield shares. Removing the hook only makes the syncs less frequent, which puts
     *      the market on the infrequent, slightly higher side. One (steps, window) point is measured with a single snapshot restore
     *      (reliable once per deploy); the scaling of the difference with the window gain is characterized in the report.
     */
    function test_deliveredPremium_boundedAndDirectional_acrossSyncCadence() external {
        if (address(KERNEL) == address(0)) return;
        // Skip the "Dawn baseline" overlay (LT service off), which delivers no premium to measure a cadence difference on.
        if (_overlayConfig().maxLt == 0) return vm.skip(true);

        uint256 snap = vm.snapshotState();
        _pinOracleFresh();
        uint256 frequentTotal = _stagedPremiumOverWindow(16, 7 days, true);
        vm.revertToState(snap); // exactly one restore per deploy (reliable on this fork)
        _pinOracleFresh();
        uint256 infrequentTotal = _stagedPremiumOverWindow(16, 7 days, false);

        assertGt(frequentTotal, 0, "arrange: a premium must accrue");
        // Direction: fewer syncs deliver at least as much premium over the window (the no-hook side stages more).
        assertGe(infrequentTotal, frequentTotal, "infrequent staging must deliver at least as much premium as frequent");
        // Bounded: the cadence difference stays below 25 basis points of the delivered premium. The observed difference for a
        // ~1% window gain is about 5 basis points; the bound leaves margin without loosening enough to hide a real drift.
        uint256 difference = infrequentTotal - frequentTotal;
        assertLe(difference * 10_000, infrequentTotal * 25, "the cadence difference exceeds the stated 25 bps bound");
        emit log_named_uint("delivered premium: frequent", frequentTotal);
        emit log_named_uint("delivered premium: infrequent", infrequentTotal);
        emit log_named_uint("cadence difference (infrequent - frequent)", difference);
    }

    /// @notice Runs one schedule over `_windowSecs` in `_steps` equal increments, each moving the senior feed by the same
    ///         amount; frequent (`_syncEach`) syncs after every increment, infrequent syncs once at the end. Returns the
    ///         cumulative liquidity premium the sync(s) staged, read from the accounting state the sync returns.
    function _stagedPremiumOverWindow(uint256 _steps, uint256 _windowSecs, bool _syncEach) internal returns (uint256 total) {
        uint256 stepTime = _windowSecs / _steps;
        uint256 perStepYieldWAD = CADENCE_TOTAL_YIELD_WAD / _steps;
        for (uint256 i = 0; i < _steps; ++i) {
            vm.warp(block.timestamp + stepTime);
            simulateSTYield(perStepYieldWAD);
            if (_syncEach) total += toUint256(_syncCommit().ltLiquidityPremium);
        }
        if (!_syncEach) total = toUint256(_syncCommit().ltLiquidityPremium);
    }

    /// @notice Sets the JT and LT premium caps through the accountant setter setUp already granted this contract the role for.
    function _setYieldShares(uint64 _maxJtWAD, uint64 _maxLtWAD) internal {
        vm.prank(OWNER_ADDRESS);
        ACCESS_MANAGER.grantRole(ADMIN_ACCOUNTANT_ROLE, address(this), 0);
        ACCOUNTANT.setMaxYieldShares(_maxJtWAD, _maxLtWAD);
    }
}

// ===========================================================================
// Overlay variants: the fuzz above runs once per overlay, each applied through the real setters in setUp
// ===========================================================================

/**
 * @notice The liquidity service off, the shipped snUSD "Dawn baseline": no minimum liquidity, no liquidity premium. The rate
 *         equivalence must hold here too, so the fuzz runs. The reads-and-redeem test is skipped: with no liquidity premium
 *         there is nothing to accrue, and those reads are exercised under the low overlay.
 */
contract RoycoHookNecessityOverlayOff is RoycoHookNecessity {
    function _overlayConfig() internal pure override returns (OverlayConfig memory) {
        return OverlayConfig({ minLiq: 0, maxJt: 1e18, maxLt: 0 });
    }

    function test_noHook_otherReads_markCheckPremiumRedeem() external override {
        vm.skip(true);
    }
}

/**
 * @notice The overlay near its caps: 95% minimum liquidity, the two premiums summing to 100%. The rate equivalence must hold
 *         here too, so the fuzz runs. The reads-and-redeem test is skipped: at 95% minimum liquidity the seeded pool is
 *         deliberately below the requirement, so the liquidity check correctly reads above 100% and redemptions are disabled,
 *         which is a low-overlay scenario.
 */
contract RoycoHookNecessityOverlayNearCaps is RoycoHookNecessity {
    function _overlayConfig() internal pure override returns (OverlayConfig memory) {
        return OverlayConfig({ minLiq: 0.95e18, maxJt: 0.5e18, maxLt: 0.5e18 });
    }

    function test_noHook_otherReads_markCheckPremiumRedeem() external override {
        vm.skip(true);
    }
}
