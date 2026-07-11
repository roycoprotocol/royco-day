// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../../lib/forge-std/src/Test.sol";
import { console2 } from "../../../../lib/forge-std/src/console2.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IGyroECLPPool } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { IRateProvider } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IVaultMock } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/test/IVaultMock.sol";
import { IVault } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IVaultErrors } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";
import {
    PoolRoleAccounts,
    SwapKind,
    TokenConfig,
    VaultSwapParams,
    AddLiquidityKind,
    AddLiquidityParams,
    RemoveLiquidityKind,
    RemoveLiquidityParams
} from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { CREATE3 } from "../../../../lib/balancer-v3-monorepo/pkg/solidity-utils/contracts/solmate/CREATE3.sol";
import { ERC20TestToken } from "../../../../lib/balancer-v3-monorepo/pkg/solidity-utils/contracts/test/ERC20TestToken.sol";
import { FixedPoint } from "../../../../lib/balancer-v3-monorepo/pkg/solidity-utils/contracts/math/FixedPoint.sol";
import { GyroECLPPool } from "../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPool.sol";
import { GyroECLPPoolFactory } from "../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { GyroECLPMath } from "../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/lib/GyroECLPMath.sol";
import { BasicAuthorizerMock } from "../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/test/BasicAuthorizerMock.sol";
import { ProtocolFeeControllerMock } from "../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/test/ProtocolFeeControllerMock.sol";
import { RateProviderMock } from "../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/test/RateProviderMock.sol";
import { VaultAdminMock } from "../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/test/VaultAdminMock.sol";
import { VaultExtensionMock } from "../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/test/VaultExtensionMock.sol";
import { VaultMock } from "../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/test/VaultMock.sol";

/**
 * @title EclpTestRouter
 * @notice Minimal trusted unlock-router for the local Balancer V3 vault: every entrypoint wraps
 *         `VAULT.unlock(abi.encodeCall(this.xHook, ...))`; hooks settle every token owed via
 *         `transferFrom(payer, VAULT) + settle` and pay every token due via `sendTo`. No permit2,
 *         no queries — quoting is done test-side with state snapshots. Payers pre-approve this
 *         router on both ERC20s and on the pool BPT (the vault spends BPT allowance on removes).
 */
contract EclpTestRouter {
    IVault internal immutable VAULT;

    constructor(IVault vault_) {
        VAULT = vault_;
    }

    modifier onlyVault() {
        require(msg.sender == address(VAULT), "EclpTestRouter: hook caller must be the vault");
        _;
    }

    function initialize(address pool, address payer, IERC20[] memory tokens, uint256[] memory amounts) external returns (uint256 bptOut) {
        return abi.decode(VAULT.unlock(abi.encodeCall(this.initializeHook, (pool, payer, tokens, amounts))), (uint256));
    }

    function initializeHook(address pool, address payer, IERC20[] memory tokens, uint256[] memory amounts) external onlyVault returns (uint256 bptOut) {
        bptOut = VAULT.initialize(pool, payer, tokens, amounts, 0, "");
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amounts[i] > 0) {
                tokens[i].transferFrom(payer, address(VAULT), amounts[i]);
                VAULT.settle(tokens[i], amounts[i]);
            }
        }
    }

    function swapExactIn(address pool, address payer, IERC20 tIn, IERC20 tOut, uint256 amtIn, uint256 minOut) external returns (uint256 amountOut) {
        return abi.decode(VAULT.unlock(abi.encodeCall(this.swapExactInHook, (pool, payer, tIn, tOut, amtIn, minOut))), (uint256));
    }

    function swapExactInHook(
        address pool,
        address payer,
        IERC20 tIn,
        IERC20 tOut,
        uint256 amtIn,
        uint256 minOut
    ) external onlyVault returns (uint256 amountOut) {
        (,, amountOut) = VAULT.swap(
            VaultSwapParams({ kind: SwapKind.EXACT_IN, pool: pool, tokenIn: tIn, tokenOut: tOut, amountGivenRaw: amtIn, limitRaw: minOut, userData: "" })
        );
        tIn.transferFrom(payer, address(VAULT), amtIn);
        VAULT.settle(tIn, amtIn);
        VAULT.sendTo(tOut, payer, amountOut);
    }

    function swapExactOut(address pool, address payer, IERC20 tIn, IERC20 tOut, uint256 amtOut, uint256 maxIn) external returns (uint256 amountIn) {
        return abi.decode(VAULT.unlock(abi.encodeCall(this.swapExactOutHook, (pool, payer, tIn, tOut, amtOut, maxIn))), (uint256));
    }

    function swapExactOutHook(
        address pool,
        address payer,
        IERC20 tIn,
        IERC20 tOut,
        uint256 amtOut,
        uint256 maxIn
    ) external onlyVault returns (uint256 amountIn) {
        (, amountIn,) = VAULT.swap(
            VaultSwapParams({ kind: SwapKind.EXACT_OUT, pool: pool, tokenIn: tIn, tokenOut: tOut, amountGivenRaw: amtOut, limitRaw: maxIn, userData: "" })
        );
        tIn.transferFrom(payer, address(VAULT), amountIn);
        VAULT.settle(tIn, amountIn);
        VAULT.sendTo(tOut, payer, amtOut);
    }

    function addLiquidityUnbalanced(
        address pool,
        address payer,
        IERC20[] memory tokens,
        uint256[] memory exactAmountsIn,
        uint256 minBpt
    ) external returns (uint256[] memory amountsIn, uint256 bptOut) {
        return abi.decode(
            VAULT.unlock(abi.encodeCall(this.addLiquidityUnbalancedHook, (pool, payer, tokens, exactAmountsIn, minBpt))), (uint256[], uint256)
        );
    }

    function addLiquidityUnbalancedHook(
        address pool,
        address payer,
        IERC20[] memory tokens,
        uint256[] memory exactAmountsIn,
        uint256 minBpt
    ) external onlyVault returns (uint256[] memory amountsIn, uint256 bptOut) {
        (amountsIn, bptOut,) = VAULT.addLiquidity(
            AddLiquidityParams({
                pool: pool,
                to: payer,
                maxAmountsIn: exactAmountsIn,
                minBptAmountOut: minBpt,
                kind: AddLiquidityKind.UNBALANCED,
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

    function removeLiquiditySingleTokenExactIn(
        address pool,
        address payer,
        uint256 bptIn,
        IERC20[] memory tokens,
        uint256 outIndex,
        uint256 minOut
    ) external returns (uint256 amountOut) {
        return abi.decode(
            VAULT.unlock(abi.encodeCall(this.removeSingleHook, (pool, payer, bptIn, tokens, outIndex, minOut))), (uint256)
        );
    }

    function removeSingleHook(
        address pool,
        address payer,
        uint256 bptIn,
        IERC20[] memory tokens,
        uint256 outIndex,
        uint256 minOut
    ) external onlyVault returns (uint256 amountOut) {
        uint256[] memory mins = new uint256[](tokens.length);
        // The vault infers the output token from the single nonzero minAmountsOut entry — it must be >= 1.
        mins[outIndex] = minOut == 0 ? 1 : minOut;
        (, uint256[] memory amountsOut,) = VAULT.removeLiquidity(
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
            if (amountsOut[i] > 0) VAULT.sendTo(tokens[i], payer, amountsOut[i]);
        }
        amountOut = amountsOut[outIndex];
    }

    function removeLiquidityProportional(address pool, address payer, uint256 bptIn, IERC20[] memory tokens)
        external
        returns (uint256[] memory amountsOut)
    {
        return abi.decode(VAULT.unlock(abi.encodeCall(this.removeProportionalHook, (pool, payer, bptIn, tokens))), (uint256[]));
    }

    function removeProportionalHook(address pool, address payer, uint256 bptIn, IERC20[] memory tokens)
        external
        onlyVault
        returns (uint256[] memory amountsOut)
    {
        uint256[] memory mins = new uint256[](tokens.length);
        (, amountsOut,) = VAULT.removeLiquidity(
            RemoveLiquidityParams({
                pool: pool,
                from: payer,
                maxBptAmountIn: bptIn,
                minAmountsOut: mins,
                kind: RemoveLiquidityKind.PROPORTIONAL,
                userData: ""
            })
        );
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amountsOut[i] > 0) VAULT.sendTo(tokens[i], payer, amountsOut[i]);
        }
    }
}

/**
 * @title ECLPExitLiquidityBase
 * @notice Harness for the stable-tilted Gyro E-CLP exit-liquidity pool study, run HEAD-TO-HEAD on two tilts.
 *         Deploys the REAL Balancer V3 vault stack (VaultMock via CREATE3) and the REAL GyroECLPPool from the
 *         vendored monorepo, locally, no fork; ONLY the two rate providers are mocked. Both pools keep the
 *         production band floor (alpha = peg - 15 bp), rotation at price 1, lambda = 4000 and the 1 bp fee;
 *         only beta is re-solved for the target balance-point composition:
 *         - tilt9999 ("candidate A"): beta = 1 + 4.74e-8, 99.99% stablecoin by value at the peg;
 *         - tilt9010 ("candidate D"): beta = 1 + 5.2988e-5 (band [-15 bp, +0.52988 bp]), 90.00% stablecoin /
 *           10.00% ST by value at the peg — same concentration character (density peaks at the peg, decays
 *           monotonically toward alpha; the quote-side ladder y(p) is IDENTICAL to candidate A's because it
 *           depends only on alpha/rotation/lambda, so drain-anchor prices, consumed fractions and densities
 *           are shared; only the ST leg differs, by a constant x-offset per unit invariant).
 *         Every battery test runs the identical procedure on both pools (vm state snapshots isolate the two
 *         runs where flows or rate steps would interfere) and emits paired METRIC lines
 *         `METRIC|<name>|...|tilt9999=<x>|tilt9010=<y>|delta=<y-x>` for direct decision-making contrast.
 *         All constants are probe-verified offline (100-digit mpmath, derive_eclp.py/derive_9010.py) and
 *         hardcoded — nothing is re-derived on-chain.
 *
 * @dev ECONOMIC MODEL. The mocked rates are the external truth: ST NAV earns 8%/yr, the yield-bearing quote
 *      stable earns 3%/yr, both marked by DISCRETE oracle steps (compounding per-step multiplication) with
 *      LINEAR intra-period fair accrual, so fair == oracle at every update instant and the fair/oracle gap at
 *      update-minus-epsilon (1.3699 bp/day for synchronized daily marks) is the arbable edge. All PnL is
 *      valued at these external fair rates — never at pool spot (except the explicitly labelled
 *      "spot-numeraire" LP-add metric, which isolates fee+impact from the fair-vs-spot standing discount).
 *
 *      DELIBERATE DEVIATIONS FROM PRODUCTION WIRING (required by the product brief):
 *      1. BOTH legs register WITH_RATE (production registers the USDC quote STANDARD). The quote here is a
 *         3%-yielding stable; test_T4_QuoteRegisteredStandard shows STANDARD wiring kills the pool in ~3 weeks.
 *      2. Both tokens are 18-decimals (yield-bearing stables are 18-dec; raw == scaled at rate 1 makes the
 *         external-fair ledger exact to the wei and isolates E-CLP+rate economics from decimal plumbing).
 *
 *      DOCUMENTED DEVIATIONS FROM THE PRE-REGISTERED TEST DESIGN (design assumed a quadratic-LVR model with
 *      the pool resting at fair; measurement shows the geometry invalidates that premise, so the affected
 *      assertions were replaced with structural/measured ones — never widened to force a pass):
 *      a. BETA-PINNING: the balance point sits essentially AT beta (beta - 1 = 4.74e-8), and the net fair
 *         drift is monotonically UP (+1.3699 bp/day). A rate-step arb is therefore a BUY of pool ST capped at
 *         beta: it recycles whatever ST inventory exit flow left in the pool ONE TIME and then starves. With
 *         no fresh exit inflow the steady-state per-update extraction is ~zero at EVERY drain state and EVERY
 *         cadence — the design's static per-state LVR table (3.5/3.6/1.8/0.4 bp/yr) is unreachable in a static
 *         pool. T2 therefore asserts: (i) the one-time recycle profit is positive and bounded by
 *         inventory x jump, (ii) steady-state extraction is below the declared measurement floor, and the
 *         sustained-flow extraction is measured where it really lives: the ST-daily/quote-weekly cadence
 *         (two-sided q* oscillation, genuinely repeatable), the sustained-flow cadence x fee breakeven grid
 *         (`_flowBreakevenSweep`) and the 365-day simulation.
 *      b. "profit == 0" assertions use DUST_PROFIT = 2e13 wei ($2e-5 on a $20M pool) as an explicit
 *         search-resolution floor: the 48-iteration ternary search leaves ~1e12-wei crumbs between rounds.
 *         bp-scale findings are ~1e21 wei, over seven orders above the floor — this hides nothing economic.
 *      c. Test 15(a): a 1e6-wei exact-in reverts in production vaults because the min-trade check runs on the
 *         POST-FEE given amount (Vault.sol:385-391); the passing dust trade is 2e6 wei and the dust-buy revert
 *         is exercised via EXACT_OUT below the minimum.
 *      d. Test 3 drains the quote leg to a 1e5-wei remainder instead of exactly zero (asset-bound rounding
 *         safety); emptiness is still asserted (<= 1e6 wei) plus the hard AssetBoundsExceeded revert.
 *      e. Test 10 asserts the fee+impact model against the SPOT-numeraire add cost (per econ-notes §4); the
 *         fair-valued cost is logged (it is NEGATIVE at drained states — joining a discounted pool at NAV is
 *         a gain, which would render a model band assertion vacuous).
 *      f. Test 14 buys the ST leg down to a 1e12-wei dust remainder instead of exactly zero: an exact-out of
 *         the FULL leg trips the pool-favoring asset-bound rounding at the corner.
 *
 *      CI NOTE (open item, no repo file changed for it): importing Balancer's VaultMock pulls two TEST-ONLY
 *      contracts over the EIP-170 runtime limit under this repo's solc settings (VaultMock 46,037 B; the real
 *      Vault it extends is itself 25,295 B at 0.8.35/via_ir/500 runs, so deploying the real vault instead
 *      would not help). Plain `forge build` and `forge test` pass — nothing oversized is deployable from
 *      src/ — but CI's `forge build --sizes` gate will flag them; whether to exempt vendored test mocks from
 *      the size gate is a maintainer decision deliberately left outside this single-file deliverable.
 */
abstract contract ECLPExitLiquidityBase is Test {
    using FixedPoint for uint256;

    /*//////////////////////////////////////////////////////////////////////////
                                     CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    uint256 internal constant SWAP_FEE = 1e14; // 1 bp
    uint256 internal constant X0_9999 = 1_000_100_009_994_972_733_910; // tilt9999 ST at the balance point (p = 1) for Y0 quote
    uint256 internal constant X0_9010 = 1_111_111_111_111_104_667_327_418; // tilt9010 ST at the balance point for Y0 quote
    uint256 internal constant Y0 = 10_000_000e18;

    /// Rate steps (integer division of the simple annual rates; compounding is per-step mulDown).
    uint256 internal constant ST_STEP_1D = 1_000_219_178_082_191_780; // 1e18 + 8e16/365
    uint256 internal constant Q_STEP_1D = 1_000_082_191_780_821_917; // 1e18 + 3e16/365
    uint256 internal constant ST_STEP_12H = 1_000_109_589_041_095_890; // 1e18 + 8e16/730
    uint256 internal constant Q_STEP_12H = 1_000_041_095_890_410_958; // 1e18 + 3e16/730
    uint256 internal constant ST_STEP_6H = 1_000_054_794_520_547_945; // 1e18 + 8e16/1460
    uint256 internal constant Q_STEP_6H = 1_000_020_547_945_205_479; // 1e18 + 3e16/1460
    uint256 internal constant ST_STEP_2D = 1_000_438_356_164_383_561; // 1e18 + 16e16/365
    uint256 internal constant Q_STEP_2D = 1_000_164_383_561_643_835; // 1e18 + 6e16/365
    uint256 internal constant Q_STEP_7D = 1_000_575_342_465_753_424; // 1e18 + 21e16/365

    /// Excess ST-over-quote fair drift per synchronized daily step: (ST_STEP_1D - Q_STEP_1D).
    uint256 internal constant EXCESS_CARRY_PER_DAY = 136_986_301_369_863;

    /// Arb search resolution (see header dev-note b). Profits at or below this are "no extractable arb".
    uint256 internal constant DUST_PROFIT = 2e13;
    uint256 internal constant ARB_TERNARY_ITERS = 48;
    uint256 internal constant ARB_MAX_ROUNDS = 8;
    uint256 internal constant ARB_LO = 2e6; // raw floor clearing the 1e6 scaled18 min-trade after the fee cut
    uint256 internal constant ARB_HI_START = 4e25; // 4x the full band depth; halved on revert
    uint256 internal constant ARB_BOUNDARY_RES = 1e15; // feasibility-boundary refinement resolution (0.001 tokens)

    /// Peak stable density per unit invariant: lambda^2 * s / 2 (tokens of quote per 1.0 of price, per 1e18 of r).
    uint256 internal constant RHO_PEAK_COEF = 5_656_854;

    /**
     * @notice Sustained-flow breakeven sweep (T2): scenario length, steady-window start (warmup excluded),
     *         daily exit flow (0.2% of fair TVL — the year sim's base flow), and the extraction-materiality
     *         floor in bp/yr*1e4 of TVL. The floor separates the two analytic regimes by construction: the
     *         sub-breakeven flow-impact crumb rate (~0.5 x impact x flow; measured ~35 in these units) sits
     *         ~14x below it and the smallest supra-breakeven margin in the grid (12h @ 0.5 bp: flow x
     *         (jump - fee) ~ 0.135 bp/yr, i.e. ~1_350; measured 1_380) sits ~2.7x above it.
     */
    uint256 internal constant FLOW_DAYS = 8;
    uint256 internal constant FLOW_WARMUP_DAYS = 4;
    uint256 internal constant FLOW_PCT = 2e15;
    uint256 internal constant FLOW_MATERIAL_BP_YR_E4 = 500;

    /*//////////////////////////////////////////////////////////////////////////
                                       STATE
    //////////////////////////////////////////////////////////////////////////*/

    IVaultMock internal vault;
    EclpTestRouter internal router;
    GyroECLPPoolFactory internal factory;
    ERC20TestToken internal st;
    ERC20TestToken internal quoteToken;
    RateProviderMock internal stRateProvider;
    RateProviderMock internal quoteRateProvider;
    address internal poolTilt9999;
    address internal poolTilt9010;
    address internal pool; // the ACTIVE pool every helper operates on; select with _usePool
    uint256 internal tilt; // active tilt index: 0 = tilt9999 (candidate A), 1 = tilt9010 (candidate D)

    address internal lp;
    address internal arber;
    address internal exiter;

    /// Fair-model bookkeeping: oracle marks + the step/period of the CURRENT accrual window (see _fairStRate).
    uint256 internal stMark;
    uint256 internal stMarkTs;
    uint256 internal stStepWad;
    uint256 internal stPeriod;
    uint256 internal qMark;
    uint256 internal qMarkTs;
    uint256 internal qStepWad;
    uint256 internal qPeriod;
    /// Test-side clock. vm.warp'd time is unreliable across snapshot restores under paused gas metering, so
    /// every warp routes through _warpTo/_warpBy and every time read uses nowTs — never block.timestamp.
    uint256 internal nowTs;
    bool internal quoteLegStandard; // true only for the T4 STANDARD-wiring pool (its oracle quote rate is pinned at 1e18)

    /*//////////////////////////////////////////////////////////////////////////
                                       SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        _warpTo(1_000_000);
        lp = makeAddr("lp");
        arber = makeAddr("arber");
        exiter = makeAddr("exiter");

        // Vault stack: exact VaultContractsDeployer non-artifact recipe with production-realistic minimums.
        BasicAuthorizerMock authorizer = new BasicAuthorizerMock();
        address predicted = CREATE3.getDeployed(bytes32(0));
        VaultAdminMock vaultAdmin = new VaultAdminMock(IVault(payable(predicted)), 90 days, 30 days, 1e6, 1e3);
        VaultExtensionMock vaultExtension = new VaultExtensionMock(IVault(payable(predicted)), vaultAdmin);
        ProtocolFeeControllerMock feeController = new ProtocolFeeControllerMock(IVaultMock(predicted), 0, 0);
        CREATE3.deploy(bytes32(0), abi.encodePacked(type(VaultMock).creationCode, abi.encode(vaultExtension, authorizer, feeController)), 0);
        vault = IVaultMock(predicted);
        router = new EclpTestRouter(IVault(predicted));

        // Tokens: band semantics require ST = token0, i.e. address(st) < address(quote); mine the ordering.
        st = new ERC20TestToken("Senior Tranche Share", "ST", 18);
        for (uint256 i = 0; i < 64; ++i) {
            quoteToken = new ERC20TestToken("Yield Bearing Stable", "YUSD", 18);
            if (address(st) < address(quoteToken)) break;
        }
        require(address(st) < address(quoteToken), "setUp: could not mine ST < quote address ordering");

        stRateProvider = new RateProviderMock();
        quoteRateProvider = new RateProviderMock();
        stMark = 1e18;
        qMark = 1e18;
        stStepWad = ST_STEP_1D;
        qStepWad = Q_STEP_1D;
        stPeriod = 1 days;
        qPeriod = 1 days;

        factory = new GyroECLPPoolFactory(IVault(predicted), 365 days, "eclp-econ-test", "eclp-econ-test");
        poolTilt9999 = _createPool(_eclpParamsA(), _derivedParamsA(), false, bytes32(uint256(1)));
        poolTilt9010 = _createPool(_eclpParamsD(), _derivedParamsD(), false, bytes32(uint256(4)));

        // Actors: mint and approve. The test contract itself is the init LP so actor PnLs are clean diffs.
        address[4] memory actors = [lp, arber, exiter, address(this)];
        for (uint256 i = 0; i < 4; ++i) {
            st.mint(actors[i], 1e9 ether);
            quoteToken.mint(actors[i], 1e9 ether);
            vm.startPrank(actors[i]);
            st.approve(address(router), type(uint256).max);
            quoteToken.approve(address(router), type(uint256).max);
            IERC20(poolTilt9999).approve(address(router), type(uint256).max);
            IERC20(poolTilt9010).approve(address(router), type(uint256).max);
            vm.stopPrank();
        }

        router.initialize(poolTilt9999, address(this), _tokens(), _two(X0_9999, Y0));
        router.initialize(poolTilt9010, address(this), _tokens(), _two(X0_9010, Y0));
        stMarkTs = nowTs;
        qMarkTs = nowTs;

        // The optimal-arb searches quote thousands of real swaps per test; pause gas metering so the
        // measurement machinery cannot hit the per-test gas cap (economics, not gas, is under test).
        vm.pauseGasMetering();

        // Wiring asserts per pool: leg identity, balance-point price, and the target tilt (this is the
        // on-chain validation of the solved 90/10 band: factory.create already ran validateParams +
        // validateDerivedParamsLimits in the constructor, and the composition check is empirical).
        for (uint256 t = 0; t < 2; ++t) {
            _usePool(t);
            (IERC20[] memory toks,,,) = vault.getPoolTokenInfo(pool);
            assertEq(address(toks[0]), address(st), "the ST tranche share must register as token0 so alpha/beta price ST in quote");
            assertApproxEqAbs(_spotPrice(), 1e18, 1e9, "the init fixture must land the scaled spot price on the peg (p = 1)");
            assertApproxEqAbs(_stableShare(), _pegStableShareWad(t), 1e12, "the balance point must hold the tilt's target stable share by value");
        }
        _usePool(0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                              POOL PARAMS (HARDCODED)
    //////////////////////////////////////////////////////////////////////////*/

    /// Candidate A: production band floor/rotation/lambda; beta retilted to 1 + 4.74e-8 for the 99.99% stable peg.
    function _eclpParamsA() internal pure returns (IGyroECLPPool.EclpParams memory) {
        return IGyroECLPPool.EclpParams({
            alpha: 998_502_246_630_054_917,
            beta: 1_000_000_047_426_806_502,
            c: 707_106_781_186_547_524,
            s: 707_106_781_186_547_524,
            lambda: 4_000_000_000_000_000_000_000
        });
    }

    /// Candidate A derived params (38-dec, 100-digit mpmath, probe-verified on-chain — never derive on-chain).
    function _derivedParamsA() internal pure returns (IGyroECLPPool.DerivedEclpParams memory) {
        return IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({
                x: -94_861_212_813_096_057_289_512_505_574_275_160_548,
                y: 31_644_119_574_235_279_926_451_292_677_567_331_631
            }),
            tauBeta: IGyroECLPPool.Vector2({
                x: 9_485_361_032_798_927_341_480_843_340_483_755,
                y: 99_999_999_550_139_629_318_738_613_277_634_649_855
            }),
            u: 47_435_349_087_064_428_054_646_736_105_011_537_103,
            v: 65_822_059_562_187_454_547_968_596_168_072_025_937,
            w: 34_177_939_987_952_174_657_394_110_961_702_013_072,
            z: -47_425_863_726_031_629_127_316_009_375_741_763_698,
            dSq: 99_999_999_999_999_999_886_624_093_342_106_115_200
        });
    }

    /**
     * @notice Candidate D (tilt9010): same alpha/rotation/lambda as candidate A; beta re-solved (100-digit
     *         mpmath bisection, derive_9010.py) so the ST value fraction at the rate-scaled peg p = 1 is
     *         exactly 10.00%. Solved band: [peg - 15 bp, peg + 0.52988 bp] (beta = 1 + 5.2988331e-5,
     *         zeta(beta) = 0.10597); density still peaks at the peg and decays monotonically toward alpha.
     */
    function _eclpParamsD() internal pure returns (IGyroECLPPool.EclpParams memory) {
        return IGyroECLPPool.EclpParams({
            alpha: 998_502_246_630_054_917,
            beta: 1_000_052_988_330_668_221,
            c: 707_106_781_186_547_524,
            s: 707_106_781_186_547_524,
            lambda: 4_000_000_000_000_000_000_000
        });
    }

    /// Candidate D derived params (38-dec, derive_9010.py; validateDerivedParamsLimits AchiAchi-1 = 4.45e6).
    function _derivedParamsD() internal pure returns (IGyroECLPPool.DerivedEclpParams memory) {
        return IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({
                x: -94_861_212_813_096_057_289_512_505_574_275_160_548,
                y: 31_644_119_574_235_279_926_451_292_677_567_331_631
            }),
            tauBeta: IGyroECLPPool.Vector2({
                x: 10_538_375_191_828_384_953_081_685_675_093_575_910,
                y: 99_443_162_903_822_885_390_594_315_002_629_343_516
            }),
            u: 52_699_794_002_462_221_061_548_226_367_550_440_681,
            v: 65_543_641_239_029_082_584_212_106_328_751_881_919,
            w: 33_899_521_664_793_802_693_637_621_122_381_869_054,
            z: -42_161_418_810_633_836_120_414_519_113_202_860_120,
            dSq: 99_999_999_999_999_999_886_624_093_342_106_115_200
        });
    }

    /// Production params (MarketDeploymentConfig.sol:276-295 literals) — the T1 contrast baseline.
    function _eclpParamsProd() internal pure returns (IGyroECLPPool.EclpParams memory) {
        return IGyroECLPPool.EclpParams({
            alpha: 998_502_246_630_054_917,
            beta: 1_000_200_040_008_001_600,
            c: 707_106_781_186_547_524,
            s: 707_106_781_186_547_524,
            lambda: 4_000_000_000_000_000_000_000
        });
    }

    /// Production derived params (identical to GyroEclpPoolDeployer.sol:23-37 in the vendored monorepo).
    function _derivedParamsProd() internal pure returns (IGyroECLPPool.DerivedEclpParams memory) {
        return IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({
                x: -94_861_212_813_096_057_289_512_505_574_275_160_547,
                y: 31_644_119_574_235_279_926_451_292_677_567_331_630
            }),
            tauBeta: IGyroECLPPool.Vector2({
                x: 37_142_269_533_113_549_537_591_131_345_643_981_951,
                y: 92_846_388_265_400_743_995_957_747_409_218_517_601
            }),
            u: 66_001_741_173_104_803_338_721_745_994_955_553_010,
            v: 62_245_253_919_818_011_890_633_399_060_291_020_887,
            w: 30_601_134_345_582_732_000_058_913_853_921_008_022,
            z: -28_859_471_639_991_253_843_240_999_485_797_747_790,
            dSq: 99_999_999_999_999_999_886_624_093_342_106_115_200
        });
    }

    function _createPool(
        IGyroECLPPool.EclpParams memory params,
        IGyroECLPPool.DerivedEclpParams memory derived,
        bool quoteStandard,
        bytes32 salt
    ) internal returns (address newPool) {
        IRateProvider[] memory provs = new IRateProvider[](2);
        provs[0] = IRateProvider(address(stRateProvider));
        provs[1] = quoteStandard ? IRateProvider(address(0)) : IRateProvider(address(quoteRateProvider));
        TokenConfig[] memory cfg = vault.buildTokenConfig(_tokens(), provs);
        PoolRoleAccounts memory roleAccounts;
        newPool = factory.create("Royco Day tilted E-CLP", "RD-ECLP", cfg, params, derived, roleAccounts, SWAP_FEE, address(0), false, false, salt);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  TILT SELECTION
    //////////////////////////////////////////////////////////////////////////*/

    /// Select the active pool every helper operates on. 0 = tilt9999 (candidate A), 1 = tilt9010 (candidate D).
    function _usePool(uint256 t) internal {
        tilt = t;
        pool = t == 0 ? poolTilt9999 : poolTilt9010;
    }

    function _tiltLabel(uint256 t) internal pure returns (string memory) {
        return t == 0 ? "tilt9999" : "tilt9010";
    }

    function _x0Of(uint256 t) internal pure returns (uint256) {
        return t == 0 ? X0_9999 : X0_9010;
    }

    /// Stable value share at the peg (derivation targets: 99.99% and 90.00%).
    function _pegStableShareWad(uint256 t) internal pure returns (uint256) {
        return t == 0 ? 999_900_000_000_000_000 : 900_000_000_000_000_000;
    }

    function _betaOf(uint256 t) internal pure returns (uint256) {
        return t == 0 ? 1_000_000_047_426_806_502 : 1_000_052_988_330_668_221;
    }

    /*//////////////////////////////////////////////////////////////////////////
                             DRAIN ANCHORS (PROBE FIXTURES)
    //////////////////////////////////////////////////////////////////////////*/

    /// Cumulative quote consumed at the anchor (of Y0). Index: 0=D0, 1=D25, 2=D50, 3=D75, 4=D95.
    /// SHARED between tilts: the quote-side ladder y(p) depends only on alpha/rotation/lambda (identical).
    function _anchorConsumed(uint256 i) internal pure returns (uint256) {
        if (i == 0) return 0;
        if (i == 1) return 2_500_000e18;
        if (i == 2) return 5_000_000e18;
        if (i == 3) return 7_500_000e18;
        return 9_500_000e18;
    }

    /// Probe-verified scaled spot at the anchor. SHARED between tilts (tilt9010 values agree within 5e-13,
    /// derive_9010.py — far inside the 2e13 landing tolerance of _drainTo).
    function _anchorSpot(uint256 i) internal pure returns (uint256) {
        if (i == 0) return 1e18;
        if (i == 1) return 999_877_968_291_000_000;
        if (i == 2) return 999_730_695_092_000_000;
        if (i == 3) return 999_493_993_012_000_000;
        return 998_961_102_691_000_000;
    }

    /// ST value share at the anchor per tilt (model input for T3; tilt9010 values from derive_9010.py).
    function _anchorStShareWad(uint256 t, uint256 i) internal pure returns (uint256) {
        if (t == 0) {
            if (i == 0) return 1e14;
            if (i == 1) return 25e16;
            if (i == 2) return 50e16;
            if (i == 3) return 75e16;
            return 95e16;
        }
        if (i == 0) return 10e16;
        if (i == 1) return 324_982_400_000_000_000;
        if (i == 2) return 549_958_900_000_000_000;
        if (i == 3) return 774_943_500_000_000_000;
        return 954_967_400_000_000_000;
    }

    /// Density/peak at the anchor (model input for T3). SHARED between tilts (depends only on lambda/rotation).
    function _anchorDensityWad(uint256 i) internal pure returns (uint256) {
        if (i == 0) return 1e18;
        if (i == 1) return 916_900_000_000_000_000;
        if (i == 2) return 682_400_000_000_000_000;
        if (i == 3) return 347_100_000_000_000_000;
        return 81_500_000_000_000_000;
    }

    function _anchorLabel(uint256 i) internal pure returns (string memory) {
        if (i == 0) return "D0";
        if (i == 1) return "D25";
        if (i == 2) return "D50";
        if (i == 3) return "D75";
        return "D95";
    }

    /**
     * @notice Drain the pool to an anchor with a single exiter EXACT_OUT sell (quote out, ST in).
     * @dev Immediately post-init only (rates 1e18, raw == scaled, exact). Fees land on the ST side, so the
     *      quote leg equals Y0 - consumed exactly and the spot lands on the probe anchor within 0.2 bp.
     */
    function _drainTo(uint256 anchorId) internal {
        if (anchorId == 0) return;
        router.swapExactOut(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), _anchorConsumed(anchorId), type(uint256).max);
        assertApproxEqAbs(_spotPrice(), _anchorSpot(anchorId), 2e13, "the drain swap must land the spot on the probe-verified anchor price");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FAIR-MODEL BOOKKEEPING
    //////////////////////////////////////////////////////////////////////////*/

    /// Fair ST rate: last oracle mark with linear intra-period accrual toward the next mark (fair == oracle at marks).
    function _fairStRate() internal view returns (uint256) {
        uint256 el = nowTs - stMarkTs;
        if (el == 0) return stMark;
        return stMark.mulDown(1e18 + (stStepWad - 1e18) * el / stPeriod);
    }

    /// Fair quote rate: same linear-accrual model at the quote cadence.
    function _fairQRate() internal view returns (uint256) {
        uint256 el = nowTs - qMarkTs;
        if (el == 0) return qMark;
        return qMark.mulDown(1e18 + (qStepWad - 1e18) * el / qPeriod);
    }

    /// Step the ST oracle by the current cadence step and re-mark.
    function _stepStOracle() internal {
        stMark = stMark.mulDown(stStepWad);
        stRateProvider.mockRate(stMark);
        stMarkTs = nowTs;
    }

    /// Step the quote oracle by the current cadence step and re-mark (mockRate is a no-op for the STANDARD pool).
    function _stepQuoteOracle() internal {
        qMark = qMark.mulDown(qStepWad);
        quoteRateProvider.mockRate(qMark);
        qMarkTs = nowTs;
    }

    function _setStCadence(uint256 stepWad, uint256 period) internal {
        stStepWad = stepWad;
        stPeriod = period;
    }

    function _setQuoteCadence(uint256 stepWad, uint256 period) internal {
        qStepWad = stepWad;
        qPeriod = period;
    }

    /// Fair price of one SCALED ST unit in SCALED quote units: (fairSt/oracleSt) / (fairQ/oracleQ). 1e18 at marks.
    function _fairScaledRatio() internal view returns (uint256) {
        uint256 qOracle = quoteLegStandard ? 1e18 : qMark;
        uint256 r1 = _fairStRate() * qOracle / stMark;
        return r1 * 1e18 / _fairQRate();
    }

    /// Fair/oracle gap in bp*1e4 (signed): the per-update jump when measured at update-minus-epsilon.
    function _jumpBpE4() internal view returns (int256) {
        return (int256(_fairScaledRatio()) - 1e18) / 1e10;
    }

    /// External fair dollar value (18-dec) of a raw token bundle — THE valuation function; pool spot never appears.
    function _valueAtFair(uint256 stRaw, uint256 qRaw) internal view returns (uint256) {
        return stRaw.mulDown(_fairStRate()) + qRaw.mulDown(_fairQRate());
    }

    function _poolTvlAtFair() internal view returns (uint256) {
        (uint256 stRaw, uint256 qRaw) = _rawBalances();
        return _valueAtFair(stRaw, qRaw);
    }

    /// BPT fair value: pro-rata share of the pool's fair TVL.
    function _bptFairValue(uint256 bpt) internal view returns (uint256) {
        return bpt * _poolTvlAtFair() / IERC20(pool).totalSupply();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                 POOL OBSERVATION
    //////////////////////////////////////////////////////////////////////////*/

    function _rawBalances() internal view returns (uint256 stRaw, uint256 qRaw) {
        (,, uint256[] memory raw,) = vault.getPoolTokenInfo(pool);
        return (raw[0], raw[1]);
    }

    function _liveBalances() internal view returns (uint256 stLive, uint256 qLive) {
        uint256[] memory live = vault.getCurrentLiveBalances(pool);
        return (live[0], live[1]);
    }

    /// Scaled spot price of ST in quote, mirroring BalancerVenueForkBase (invariant + calcSpotPrice0in1).
    function _spotPrice() internal view returns (uint256) {
        (IGyroECLPPool.EclpParams memory params, IGyroECLPPool.DerivedEclpParams memory derived) = GyroECLPPool(pool).getECLPParams();
        uint256[] memory live = vault.getCurrentLiveBalances(pool);
        (int256 inv,) = GyroECLPMath.calculateInvariantWithError(live, params, derived);
        return GyroECLPMath.calcSpotPrice0in1(live, params, derived, inv);
    }

    function _invariant() internal view returns (uint256) {
        (IGyroECLPPool.EclpParams memory params, IGyroECLPPool.DerivedEclpParams memory derived) = GyroECLPPool(pool).getECLPParams();
        uint256[] memory live = vault.getCurrentLiveBalances(pool);
        (int256 inv,) = GyroECLPMath.calculateInvariantWithError(live, params, derived);
        return uint256(inv);
    }

    /// Stable share of pool value at pool spot (T1 geometry metric).
    function _stableShare() internal view returns (uint256) {
        (uint256 stLive, uint256 qLive) = _liveBalances();
        return qLive * 1e18 / (stLive.mulDown(_spotPrice()) + qLive);
    }

    /// ST value share at spot, in bp*1e4 (drain tracking).
    function _stValueShareBpE4() internal view returns (uint256) {
        (uint256 stLive, uint256 qLive) = _liveBalances();
        uint256 stVal = stLive.mulDown(_spotPrice());
        return stVal * 1e8 / (stVal + qLive);
    }

    /*//////////////////////////////////////////////////////////////////////////
                              OPTIMAL-ARB MACHINERY
    //////////////////////////////////////////////////////////////////////////*/

    /// All time control routes through the test-side clock (see `nowTs`).
    function _warpTo(uint256 t) internal {
        nowTs = t;
        vm.warp(t);
    }

    function _warpBy(uint256 dt) internal {
        _warpTo(nowTs + dt);
    }

    /**
     * @notice State snapshot that also records the test-side clock: state restores reset the EVM env
     *         unreliably, so every restore re-warps to the capture-time clock explicitly.
     */
    function _snapState() internal returns (uint256 id, uint256 ts) {
        ts = nowTs;
        id = vm.snapshotState();
    }

    function _restoreState(uint256 id, uint256 ts) internal {
        // Delete on revert: tens of thousands of quotes are snapshotted per test and retained snapshots
        // accumulate full state copies.
        vm.revertToStateAndDelete(id);
        _warpTo(ts);
    }

    /// Snapshot-wrapped exact quote of an EXACT_IN swap by the arber; reverts surface as (false, 0).
    function _quoteSwap(IERC20 tIn, IERC20 tOut, uint256 amtIn) internal returns (bool ok, uint256 out) {
        (uint256 snap, uint256 ts) = _snapState();
        try router.swapExactIn(pool, arber, tIn, tOut, amtIn, 0) returns (uint256 o) {
            ok = true;
            out = o;
        } catch {
            ok = false;
        }
        _restoreState(snap, ts);
    }

    /// Net profit at fair of a hypothetical EXACT_IN swap (very negative when the quote reverts).
    function _netProfit(bool sellSt, uint256 amtIn) internal returns (int256) {
        (bool ok, uint256 out) =
            sellSt ? _quoteSwap(IERC20(address(st)), IERC20(address(quoteToken)), amtIn) : _quoteSwap(IERC20(address(quoteToken)), IERC20(address(st)), amtIn);
        if (!ok) return type(int256).min / 2;
        uint256 fairIn = sellSt ? amtIn.mulDown(_fairStRate()) : amtIn.mulDown(_fairQRate());
        uint256 fairOut = sellSt ? out.mulDown(_fairQRate()) : out.mulDown(_fairStRate());
        return int256(fairOut) - int256(fairIn);
    }

    /**
     * @notice Best strictly-positive-net trade in one direction: marginal-edge precheck (concavity makes a
     *         non-positive marginal edge at zero size sufficient to rule the direction out), revert-halving
     *         upper bound with feasibility-boundary refinement (beta/alpha truncation IS the optimum when the
     *         profit is still rising there), then a 48-iteration ternary search on the concave profit curve.
     */
    function _bestDirection(bool sellSt) internal returns (int256 bestP, uint256 bestA) {
        uint256 p = _spotPrice();
        uint256 qStar = _fairScaledRatio();
        uint256 feeComplement = 1e18 - vault.getStaticSwapFeePercentage(pool);
        if (sellSt) {
            if (p.mulDown(feeComplement) <= qStar) return (0, 0);
        } else {
            if (qStar.mulDown(feeComplement) <= p) return (0, 0);
        }

        IERC20 tIn = sellSt ? IERC20(address(st)) : IERC20(address(quoteToken));
        IERC20 tOut = sellSt ? IERC20(address(quoteToken)) : IERC20(address(st));

        uint256 hi = ARB_HI_START;
        bool ok;
        while (hi >= ARB_LO) {
            (ok,) = _quoteSwap(tIn, tOut, hi);
            if (ok) break;
            hi >>= 1;
        }
        if (hi < ARB_LO) return (0, 0);
        if (hi < ARB_HI_START) {
            uint256 bad = hi << 1;
            uint256 iters;
            while (bad - hi > ARB_BOUNDARY_RES && iters++ < 64) {
                uint256 mid = hi + (bad - hi) / 2;
                (ok,) = _quoteSwap(tIn, tOut, mid);
                if (ok) hi = mid;
                else bad = mid;
            }
        }

        uint256 a = ARB_LO;
        uint256 b = hi;
        int256 pv = _netProfit(sellSt, b);
        if (pv > bestP) (bestP, bestA) = (pv, b);
        for (uint256 i = 0; i < ARB_TERNARY_ITERS && b > a + 1; ++i) {
            uint256 m1 = a + (b - a) / 3;
            uint256 m2 = b - (b - a) / 3;
            int256 p1 = _netProfit(sellSt, m1);
            int256 p2 = _netProfit(sellSt, m2);
            if (p1 > bestP) (bestP, bestA) = (p1, m1);
            if (p2 > bestP) (bestP, bestA) = (p2, m2);
            if (p1 < p2) a = m1 + 1;
            else b = m2 - 1;
        }
        if (bestP <= 0) return (0, 0);
    }

    /// Optimal single-swap arb net of fee, valued at fair; profit == 0 when no candidate is strictly positive.
    function _optimalArb() internal returns (uint256 profit, uint256 amountIn, bool sellSt) {
        (int256 ps, uint256 as_) = _bestDirection(true);
        (int256 pb, uint256 ab) = _bestDirection(false);
        if (ps <= 0 && pb <= 0) return (0, 0, false);
        if (ps >= pb) return (uint256(ps), as_, true);
        return (uint256(pb), ab, false);
    }

    /**
     * @notice Execute `_optimalArb` for real (arber) until the residual optimum drops to the DUST floor.
     * @dev Each executed round asserts the realized fair-valued PnL equals the quoted optimum — the
     *      coherence check demanded for every answer-grade profit number in this file.
     */
    function _arbToFeeEdge() internal returns (uint256 total) {
        for (uint256 round = 0; round < ARB_MAX_ROUNDS; ++round) {
            (uint256 profit, uint256 amt, bool sellSt) = _optimalArb();
            if (profit <= DUST_PROFIT) break;
            int256 stBefore = int256(st.balanceOf(arber));
            int256 qBefore = int256(quoteToken.balanceOf(arber));
            if (sellSt) router.swapExactIn(pool, arber, IERC20(address(st)), IERC20(address(quoteToken)), amt, 0);
            else router.swapExactIn(pool, arber, IERC20(address(quoteToken)), IERC20(address(st)), amt, 0);
            int256 realized = (int256(st.balanceOf(arber)) - stBefore) * int256(_fairStRate()) / 1e18
                + (int256(quoteToken.balanceOf(arber)) - qBefore) * int256(_fairQRate()) / 1e18;
            assertEq(realized, int256(profit), "the realized arb PnL at fair must equal the quoted optimum (coherent measurement)");
            total += profit;
        }
    }

    /**
     * @notice One rate-update measurement event. Caller must have warped to (mark boundary - 1s).
     *         Measures the fair/oracle jump, extracts the pre-update optimum, steps the selected oracles at
     *         the boundary, then folds the post-update residue into the same event's profit.
     */
    function _runEvent(bool stepSt, bool stepQ) internal returns (int256 jumpE4, uint256 profit) {
        jumpE4 = _jumpBpE4();
        profit = _arbToFeeEdge();
        _warpBy(1);
        if (stepSt) _stepStOracle();
        if (stepQ) _stepQuoteOracle();
        profit += _arbToFeeEdge();
    }

    /// N synchronized events at the current (equal) cadence; also reports the ST fair inventory before event 0.
    function _runSyncEvents(uint256 n) internal returns (int256[] memory jumps, uint256[] memory profits, uint256 invFairAtFirstEvent) {
        jumps = new int256[](n);
        profits = new uint256[](n);
        for (uint256 e = 0; e < n; ++e) {
            _warpTo(stMarkTs + stPeriod - 1);
            if (e == 0) {
                (uint256 stRaw,) = _rawBalances();
                invFairAtFirstEvent = stRaw.mulDown(_fairStRate());
            }
            (jumps[e], profits[e]) = _runEvent(true, true);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                          T2 FLOW-BREAKEVEN MACHINERY
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Precondition the pool to a target spot with a binary-searched real exiter ST sell (spot is
     *         strictly decreasing in the sell size). Executes the largest size whose landed spot is still at
     *         or below the target, so the first mark's arb trims the residual gap to the exact resting point.
     */
    function _sellToSpot(uint256 targetSpot) internal {
        uint256 lo = 0;
        uint256 hi = 4e24;
        for (uint256 i = 0; i < 44; ++i) {
            uint256 mid = lo + (hi - lo) / 2;
            (uint256 snap, uint256 ts) = _snapState();
            router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), mid, 0);
            uint256 sp = _spotPrice();
            _restoreState(snap, ts);
            if (sp > targetSpot) lo = mid;
            else hi = mid;
        }
        router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), hi, 0);
    }

    /**
     * @notice One sustained-flow scenario of the cadence/fee breakeven sweep: FLOW_DAYS of FLOW_PCT daily ST
     *         exit flow (10h-of-day offset, never colliding with a mark) with the optimal arb executed at
     *         every synchronized update boundary. Sub-breakeven scenarios (per-period jump < fee) are
     *         preconditioned to their analytic resting spot (1+jump)(1-fee) so the steady window measures the
     *         stationary regime rather than the multi-week approach transient. Caller must snapshot/restore.
     * @return steadyBpYrE4 annualized steady-window arb extraction in bp/yr*1e4 of average fair TVL
     * @return steadyProfit raw steady-window arb profit at fair (wei)
     * @return spotEnd scaled spot right after the final boundary arb (before that mark's rate step)
     * @return stRawEnd raw ST leg at the same instant (beta-strip vs retained-inventory discriminator)
     */
    function _flowScenario(uint256 stStep, uint256 qStep, uint256 period, uint256 feeWad)
        internal
        returns (uint256 steadyBpYrE4, uint256 steadyProfit, uint256 spotEnd, uint256 stRawEnd)
    {
        if (feeWad != SWAP_FEE) vault.manualUnsafeSetStaticSwapFeePercentage(pool, feeWad);
        uint256 jump = EXCESS_CARRY_PER_DAY * period / 1 days;
        if (jump < feeWad) _sellToSpot((1e18 + jump).mulDown(1e18 - feeWad));
        _setStCadence(stStep, period);
        _setQuoteCadence(qStep, period);

        uint256 steadyStartTs = nowTs + FLOW_WARMUP_DAYS * 1 days;
        uint256 endTs = nowTs + FLOW_DAYS * 1 days;
        uint256 nextFlowTs = nowTs + 10 hours;
        uint256 tvlSum;
        uint256 tvlN;
        while (stMarkTs + period <= endTs) {
            uint256 boundary = stMarkTs + period;
            while (nextFlowTs < boundary) {
                _warpTo(nextFlowTs);
                uint256 stAmt = _poolTvlAtFair().mulDown(FLOW_PCT) * 1e18 / _fairStRate();
                router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), stAmt, 0);
                nextFlowTs += 1 days;
            }
            _warpTo(boundary - 1);
            uint256 profit = _arbToFeeEdge();
            if (nowTs >= steadyStartTs) {
                steadyProfit += profit;
                tvlSum += _poolTvlAtFair();
                ++tvlN;
            }
            spotEnd = _spotPrice();
            (stRawEnd,) = _rawBalances();
            _warpBy(1);
            _stepStOracle();
            _stepQuoteOracle();
        }
        steadyBpYrE4 = _bpE4(steadyProfit * 365 / (FLOW_DAYS - FLOW_WARMUP_DAYS), tvlSum / tvlN);
    }

    /*//////////////////////////////////////////////////////////////////////////
                               T3 ADD-COST MACHINERY
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Single-sided quote add by the LP; returns both cost metrics in bp*1e4 (signed) and the BPT out.
     *         costFair values the minted BPT at external fair rates (the primary economics), costSpot values
     *         pool ST at the PRE-ADD pool spot (isolates fee+impact from the standing fair-vs-spot discount).
     */
    function _singleSidedAdd(uint256 quoteRawIn) internal returns (int256 costFairE4, int256 costSpotE4, uint256 bptOut) {
        uint256 spotPre = _spotPrice();
        uint256[] memory amountsIn;
        (amountsIn, bptOut) = router.addLiquidityUnbalanced(pool, lp, _tokens(), _two(0, quoteRawIn), 0);
        assertEq(amountsIn[1], quoteRawIn, "the unbalanced add must pull the exact quote amount");

        uint256 depositFair = quoteRawIn.mulDown(_fairQRate());
        costFairE4 = (int256(depositFair) - int256(_bptFairValue(bptOut))) * 1e8 / int256(depositFair);

        (uint256 stLive, uint256 qLive) = _liveBalances();
        uint256 bptSpotVal = bptOut * (stLive.mulDown(spotPre) + qLive) / IERC20(pool).totalSupply();
        uint256 depositScaled = quoteRawIn.mulDown(quoteLegStandard ? 1e18 : qMark);
        costSpotE4 = (int256(depositScaled) - int256(bptSpotVal)) * 1e8 / int256(depositScaled);
    }

    /// Fee+impact model of the spot-numeraire add cost for the ACTIVE tilt, in bp*1e4 (econ-notes §4).
    function _addCostModelBpE4(uint256 anchorId, uint256 sizeRaw) internal view returns (uint256) {
        uint256 w = _anchorStShareWad(tilt, anchorId);
        uint256 rho = _invariant() / 1e18 * RHO_PEAK_COEF * _anchorDensityWad(anchorId) / 1e18 * 1e18; // wei of quote per 1.0 price
        uint256 dpWad = sizeRaw.mulDown(w) * 1e18 / rho;
        uint256 costWad = SWAP_FEE.mulDown(w) + w.mulDown(dpWad) / 2;
        return costWad / 1e10;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      UTILS
    //////////////////////////////////////////////////////////////////////////*/

    function _tokens() internal view returns (IERC20[] memory toks) {
        toks = new IERC20[](2);
        toks[0] = IERC20(address(st));
        toks[1] = IERC20(address(quoteToken));
    }

    function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }

    /// Fraction num/den in bp*1e4.
    function _bpE4(uint256 num, uint256 den) internal pure returns (uint256) {
        return num * 1e8 / den;
    }

    /// Grep-friendly metric line: METRIC|<table>|k1=v1|k2=v2|...
    function _logMetric(string memory table, string memory kv) internal pure {
        console2.log(string.concat("METRIC|", table, "|", kv));
    }

    function _logVerdict(string memory question, string memory classification, string memory numbers) internal pure {
        console2.log(string.concat("VERDICT|", question, "|", classification, "|", numbers));
    }

    /**
     * @notice Paired head-to-head metric line: METRIC|<name>|<ctx>|tilt9999=<a>|tilt9010=<b>|delta=<b-a>.
     *         One line per metric name so every battery figure directly juxtaposes the two tilts.
     */
    function _logPaired(string memory name, string memory ctx, int256 a, int256 b) internal pure {
        string memory prefix = bytes(ctx).length == 0 ? string.concat("METRIC|", name) : string.concat("METRIC|", name, "|", ctx);
        console2.log(string.concat(prefix, "|tilt9999=", vm.toString(a), "|tilt9010=", vm.toString(b), "|delta=", vm.toString(b - a)));
    }

    /// Unsigned convenience wrapper for `_logPaired`.
    function _logPairedU(string memory name, string memory ctx, uint256 a, uint256 b) internal pure {
        _logPaired(name, ctx, int256(a), int256(b));
    }

    function _u(uint256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }

    function _i(int256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }
}

/**
 * @title Test_PoolEconomics_ECLPExitLiquidity
 * @notice T1 composition/concentration, T2 rate-update arbs, T3 single-sided LP statics and T4 wiring/edge
 *         behavior of the stable-tilted E-CLP exit-liquidity pool, against the real locally-deployed Balancer
 *         V3 vault + GyroECLPPool with only the two rate providers mocked. setUp initializes BOTH tilts at
 *         their exact balance points (tilt9999 = 99.99% stable, tilt9010 = 90.00% stable); each test runs the
 *         identical procedure on both pools (snapshot-isolated), conditions them with real swaps (drain
 *         anchors), values every PnL at the external fair rates and emits paired tilt9999/tilt9010 metric
 *         lines. See the base-contract header for the economic model, the beta-pinning analysis and the
 *         documented deviations from the pre-registered design.
 */
contract Test_PoolEconomics_ECLPExitLiquidity is ECLPExitLiquidityBase {
    using FixedPoint for uint256;

    /*//////////////////////////////////////////////////////////////////////////
                       T1 — COMPOSITION & CONCENTRATION (Q1)
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice At the balance point tilt9999 holds 99.99% and tilt9010 holds 90.00% stablecoin by value, both
     *         with the scaled spot on the peg. Tolerances are init-fixture rounding only (probe measured
     *         999_900_000_000_000_602 for tilt9999; derive_9010.py bisected tilt9010's beta to 90.00% exactly).
     */
    function test_T1_CompositionAtBalancePoint_HeadToHead() public {
        uint256[2] memory share;
        uint256[2] memory spot;
        uint256[2] memory xLive;
        for (uint256 t = 0; t < 2; ++t) {
            _usePool(t);
            share[t] = _stableShare();
            spot[t] = _spotPrice();
            (xLive[t],) = _liveBalances();
            assertApproxEqAbs(share[t], _pegStableShareWad(t), 1e12, "the balance point must hold the tilt's solved stable share by value");
            assertApproxEqAbs(spot[t], 1e18, 1e9, "the scaled spot at the balance point must be the peg");
        }
        _logPairedU("T1_COMPOSITION_stable_share_e18", "", share[0], share[1]);
        _logPairedU("T1_COMPOSITION_spot", "", spot[0], spot[1]);
        _logPairedU("T1_COMPOSITION_x_live", "", xLive[0], xLive[1]);
    }

    /**
     * @notice Contrast: the PRODUCTION E-CLP params hold only ~71.86% stable at the same peg — both re-tilts
     *         are real parameter changes, not properties of the production pool.
     */
    function test_T1_CompositionContrast_ProductionParams_Is7186PctStable() public {
        _usePool(0);
        uint256 share9999 = _stableShare();
        _usePool(1);
        uint256 share9010 = _stableShare();
        address pool2 = _createPool(_eclpParamsProd(), _derivedParamsProd(), false, bytes32(uint256(2)));
        router.initialize(pool2, address(this), _tokens(), _two(3_915_949_626_111_194_314_237_000, Y0));
        pool = pool2;
        uint256 shareProd = _stableShare();
        assertApproxEqAbs(shareProd, 718_599_899_300_907_097, 1e12, "the production params must hold ~71.86% stable at the peg (probe fixture)");
        _logMetric(
            "T1_COMPOSITION",
            string.concat("pool=production|share_e18=", _u(shareProd), "|tilt9999_share_e18=", _u(share9999), "|tilt9010_share_e18=", _u(share9010))
        );
    }

    /**
     * @notice Walk the whole band with 10 successive exact-out drains along the probe fixture — on BOTH
     *         tilts — and verify per pool: (a) each landed spot matches the fixture price, (b) stable depth
     *         per unit price decays STRICTLY MONOTONICALLY toward alpha, (c) the band edge is a hard
     *         AssetBoundsExceeded revert once the quote leg is empty. Pure geometry: rates untouched. The
     *         fixture (prices + consumed fractions) is SHARED: the quote-side ladder is identical by
     *         construction; the paired densities must therefore match almost exactly — a strong on-chain
     *         cross-check of the derivation.
     */
    function test_T1_ConcentrationProfile_DepthDecaysMonotonicallyTowardAlpha() public {
        uint256[10] memory density9999 = _runProfile(0);
        uint256[10] memory density9010 = _runProfile(1);
        uint256[10] memory prices = _profilePrices();
        for (uint256 k = 0; k < 10; ++k) {
            assertApproxEqRel(density9010[k], density9999[k], 1e12, "the quote-side depth ladder must be identical across tilts (1e-6 rel)");
            _logPairedU("T1_PROFILE_density_per_price", string.concat("bucket_to_p=", _u(prices[k])), density9999[k], density9010[k]);
        }
    }

    function _profilePrices() internal pure returns (uint256[10] memory) {
        return [
            uint256(999_950_000_000_000_000),
            999_900_000_000_000_000,
            999_800_000_000_000_000,
            999_730_695_092_000_000,
            999_500_000_000_000_000,
            999_250_000_000_000_000,
            999_000_000_000_000_000,
            998_750_000_000_000_000,
            998_600_000_000_000_000,
            998_502_246_630_054_917
        ];
    }

    /// Band-walk body for one tilt (snapshot-isolated); returns the per-bucket depth densities.
    function _runProfile(uint256 t) internal returns (uint256[10] memory density) {
        (uint256 snap, uint256 snapTs) = _snapState();
        _usePool(t);
        uint256[10] memory prices = _profilePrices();
        uint256[10] memory consumedFrac = [
            uint256(104_914_186_824_799_411),
            206_782_139_993_098_364,
            391_594_962_611_119_971,
            499_999_999_747_306_619,
            745_562_192_996_218_533,
            877_265_669_269_450_906,
            942_998_202_947_906_094,
            978_868_776_821_093_078,
            992_840_104_803_611_530,
            1e18
        ];

        uint256 prevPrice = 1e18;
        uint256 cumOut;
        uint256 prevDensity = type(uint256).max;
        for (uint256 k = 0; k < 10; ++k) {
            uint256 legOut;
            if (k < 9) {
                uint256 cumTarget = consumedFrac[k] * (Y0 / 1e18);
                legOut = cumTarget - cumOut;
            } else {
                // Final leg: drain to a 1e5-wei remainder (deviation d in the header — bounds-safe emptiness).
                (, uint256 qRaw) = _rawBalances();
                legOut = qRaw - 1e5;
            }
            router.swapExactOut(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), legOut, type(uint256).max);
            cumOut += legOut;

            uint256 spot = _spotPrice();
            uint256 width = prevPrice - prices[k];
            if (k < 9) {
                assertApproxEqAbs(spot, prices[k], width / 200, "each drain leg must land within 0.5% of the bucket price-drop of the fixture price");
            }
            density[k] = legOut * 1e18 / width;
            assertLt(density[k], prevDensity, "stable depth per unit price must decay strictly monotonically toward alpha");
            prevDensity = density[k];
            prevPrice = prices[k];
        }

        (, uint256 qEnd) = _rawBalances();
        assertLe(qEnd, 1e6, "the quote leg must be economically empty (<= 1e6 wei) at the band edge");
        vm.expectRevert(GyroECLPMath.AssetBoundsExceeded.selector);
        router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), 1e18, 0);
        _restoreState(snap, snapTs);
    }

    /*//////////////////////////////////////////////////////////////////////////
                          T2 — RATE-UPDATE ARBS (Q2)
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Synchronized daily updates, 1 bp fee, across all five drain anchors, HEAD-TO-HEAD. The per-update
     *         jump is 1.3699 bp; the FIRST post-equilibration event recycles ST inventory one time (positive,
     *         bounded by inventory x jump) and the STEADY-STATE per-update extraction is ~zero on BOTH tilts —
     *         tilt9999 because the recycle strips the leg AT beta and the monotone up-drift never re-opens a
     *         sell edge (header deviation a), tilt9010 because even though its resting spot (1+j)(1-fee) =
     *         1.0000037 sits BELOW beta (inventory retained, ~333k ST), the rate rescale moves a concentrated
     *         pool's spot by only ~j*XY/(rho*(X+Y/p)) ~ 1e-9, so no gap re-opens either. The tilts differ in
     *         the SIZE of the one-time recycle (tilt9010 partial-strips a 100x larger inventory).
     *         Verdict: sync-daily/1bp is NOT a nasty arb on either tilt.
     */
    function test_T2_RateStepArb_SyncDaily1bpFee_AcrossDrainStates() public {
        for (uint256 i = 0; i < 5; ++i) {
            (uint256 e1A, uint256 sA) = _runSyncDailyAtAnchor(0, i);
            (uint256 e1D, uint256 sD) = _runSyncDailyAtAnchor(1, i);
            _logPairedU("T2_ARB_sync24h_event1_recycle", string.concat("drain=", _anchorLabel(i)), e1A, e1D);
            _logPairedU("T2_ARB_sync24h_steady_bp_yr_e4", string.concat("drain=", _anchorLabel(i)), sA, sD);
        }
        _logVerdict("Q2_sync_daily_1bp", "nasty=false_both_tilts", "steady_state_extraction~0_at_all_drain_states");
    }

    /// Sync-daily measurement body for one (tilt, anchor); snapshot-isolated.
    function _runSyncDailyAtAnchor(uint256 t, uint256 i) internal returns (uint256 event1, uint256 steadyBpYrE4) {
        (uint256 snap, uint256 snapTs) = _snapState();
        _usePool(t);
        _drainTo(i);
        uint256 equil0 = _arbToFeeEdge();
        uint256 tvl = _poolTvlAtFair();
        (int256[] memory jumps, uint256[] memory profits, uint256 invFair) = _runSyncEvents(7);

        uint256 steadySum;
        for (uint256 e = 0; e < 7; ++e) {
            assertApproxEqAbs(jumps[e], int256(13_699), 100, "the sync-daily fair/oracle jump must be 1.3699 bp (pure fair-model arithmetic)");
            if (e >= 2) steadySum += profits[e];
        }
        uint256 steadyAvg = steadySum / 5;
        steadyBpYrE4 = _bpE4(steadyAvg * 365, tvl);
        event1 = profits[0];

        assertGt(profits[0], 0, "the first post-equilibration update must recycle the ST inventory for a positive one-time profit");
        assertLe(
            profits[0],
            invFair.mulDown(uint256(jumps[0]) * 1e10),
            "the one-time recycle profit cannot exceed the ST inventory value times the full fair/oracle jump"
        );
        assertLe(steadyAvg, DUST_PROFIT, "steady-state per-update extraction must be below the measurement floor: the recycle is one-time");
        assertLe(steadyBpYrE4, 100_000, "VERDICT: sync-daily updates at 1 bp fee must not be a nasty arb (annualized steady extraction <= 10 bp)");

        _restoreState(snap, snapTs);
        _logMetric(
            "T2_ARB",
            string.concat(
                "pool=", _tiltLabel(t), "|drain=", _anchorLabel(i), "|cadence=24h|fee_bp_e4=10000|jump_bp_e4=", _i(jumps[0]), "|equil_recycle=",
                _u(equil0), "|event1_recycle=", _u(profits[0]), "|steady_avg=", _u(steadyAvg), "|inv_fair_at_event1=", _u(invFair)
            )
        );
    }

    /**
     * @notice Synchronized 12h updates, 1 bp fee, D50, HEAD-TO-HEAD: after the one-time recycle (event 1
     *         completes the drain-discount recycling up to the 12h drift edge), NO steady-state event finds a
     *         strictly positive trade on either tilt — the 0.685 bp half-day edge never re-opens from the
     *         resting point. Both resting targets (1+j)(1-fee) = 0.99997 sit below BOTH betas, and the arb
     *         crosses the SAME price interval on both tilts (x-offset constant cancels), so the paired event-1
     *         recycles are predicted near-identical — logged as a cross-tilt invariance check.
     */
    function test_T2_RateStepArb_SyncTwiceDaily1bpFee_NoSteadyStateProfit() public {
        uint256 e1A = _runSync12hAtD50(0);
        uint256 e1D = _runSync12hAtD50(1);
        _logPairedU("T2_ARB_sync12h_event1_recycle", "drain=D50", e1A, e1D);
    }

    /// Sync-12h measurement body for one tilt at D50; snapshot-isolated.
    function _runSync12hAtD50(uint256 t) internal returns (uint256 event1) {
        (uint256 snap, uint256 snapTs) = _snapState();
        _usePool(t);
        _drainTo(2);
        uint256 equil0 = _arbToFeeEdge();
        _setStCadence(ST_STEP_12H, 12 hours);
        _setQuoteCadence(Q_STEP_12H, 12 hours);
        (int256[] memory jumps, uint256[] memory profits, uint256 invFair) = _runSyncEvents(7);

        for (uint256 e = 0; e < 7; ++e) {
            assertApproxEqAbs(jumps[e], int256(6_849), 100, "the sync-12h fair/oracle jump must be 0.6849 bp");
            if (e >= 1) {
                assertLe(profits[e], DUST_PROFIT, "no steady-state 12h event may find an extractable trade (edge 0.685 bp < 1 bp fee from the resting edge)");
            }
        }
        assertLe(profits[0], invFair.mulDown(uint256(jumps[0]) * 1e10), "the event-1 recycle completion must be bounded by inventory x jump");
        event1 = profits[0];
        _restoreState(snap, snapTs);
        _logMetric(
            "T2_ARB",
            string.concat(
                "pool=", _tiltLabel(t), "|drain=D50|cadence=12h|fee_bp_e4=10000|jump_bp_e4=", _i(jumps[0]), "|equil_recycle=", _u(equil0),
                "|event1_recycle=", _u(profits[0]), "|steady_events_profit=0|arb_bp_yr_e4=0"
            )
        );
    }

    /**
     * @notice Asynchronous daily updates (quote offset 12h), D0 and D50, HEAD-TO-HEAD. The design predicted
     *         ~50 bp/yr from the 2.19 bp ST-update snap; measurement shows beta-pinning caps the pre-update
     *         pool price ~at the peg so the snap never opens a sell edge (post-update q* is only 0.41 bp below
     *         the pool price, under the 1 bp fee), and the buy side starves after the one-time recycle: NOT
     *         repeatable extraction (header deviation a). This holds for BOTH tilts: the ST-event buy target
     *         (1+1.78e-4)(1-1e-4) = 1.0000779 exceeds even tilt9010's beta (1 + 5.3e-5), so both pools strip
     *         and starve; tilt9010 merely recycles a ~1000x larger inventory in event 1.
     */
    function test_T2_RateStepArb_AsyncDaily12hOffset_BetaPinnedNotRepeatable() public {
        uint256 s0A = _runAsyncCadenceAtAnchor(0, 0);
        uint256 s0D = _runAsyncCadenceAtAnchor(1, 0);
        uint256 s2A = _runAsyncCadenceAtAnchor(0, 2);
        uint256 s2D = _runAsyncCadenceAtAnchor(1, 2);
        _logPairedU("T2_ARB_async12h_steady_bp_yr_e4", "drain=D0", s0A, s0D);
        _logPairedU("T2_ARB_async12h_steady_bp_yr_e4", "drain=D50", s2A, s2D);
        _logVerdict("Q2_async_12h_offset", "nasty=false_both_tilts", "beta_pinning_caps_the_snap;steady_extraction~0");
    }

    /// Async-cadence measurement body (own frame keeps the caller within via_ir stack limits); snapshot-isolated.
    function _runAsyncCadenceAtAnchor(uint256 t, uint256 anchor) internal returns (uint256 steadyBpYrE4) {
        (uint256 snap, uint256 snapTs) = _snapState();
        _usePool(t);
        _drainTo(anchor);
        uint256 equil0 = _arbToFeeEdge();
        uint256 tvl = _poolTvlAtFair();

        // Bootstrap the 12h offset with an honest half-step quote mark.
        _setQuoteCadence(Q_STEP_12H, 12 hours);
        _warpTo(qMarkTs + 12 hours - 1);
        (, uint256 bootstrapProfit) = _runEvent(false, true);
        _setQuoteCadence(Q_STEP_1D, 1 days);

        int256[] memory stJumps = new int256[](7);
        uint256[] memory stProfits = new uint256[](7);
        int256[] memory qJumps = new int256[](7);
        uint256[] memory qProfits = new uint256[](7);
        for (uint256 d = 0; d < 7; ++d) {
            _warpTo(stMarkTs + 1 days - 1);
            (stJumps[d], stProfits[d]) = _runEvent(true, false);
            _warpTo(qMarkTs + 1 days - 1);
            (qJumps[d], qProfits[d]) = _runEvent(false, true);
        }

        uint256 steadySum;
        for (uint256 d = 2; d < 7; ++d) {
            assertApproxEqAbs(stJumps[d], int256(17_807), 100, "the async ST-update fair/oracle gap must be ~1.78 bp (24h ST + 12h quote staleness)");
            assertApproxEqAbs(qJumps[d], int256(2_740), 100, "the async quote-update fair/oracle gap must be ~0.27 bp (12h ST + 24h quote staleness)");
            assertLe(stProfits[d], DUST_PROFIT, "steady-state async ST-update events must find no extractable trade (beta-pinned, inventory-starved)");
            assertLe(qProfits[d], DUST_PROFIT, "steady-state async quote-update events must find no extractable trade");
            steadySum += stProfits[d] + qProfits[d];
        }
        // steadySum accumulates over a 5-DAY window (d = 2..6, BOTH event types of each day), so the correct
        // annualization is (steadySum / 5 days) * 365 — dividing by the 10 events instead of the 5 days
        // understated the annualized extraction by exactly 2x.
        steadyBpYrE4 = _bpE4(steadySum * 365 / 5, tvl);
        assertLe(steadyBpYrE4, 100_000, "VERDICT: async daily/12h-offset updates must not sustain repeatable extraction in a static pool");

        _restoreState(snap, snapTs);
        _logMetric(
            "T2_ARB",
            string.concat(
                "pool=", _tiltLabel(t), "|drain=", _anchorLabel(anchor), "|cadence=async12h|fee_bp_e4=10000|st_jump_bp_e4=", _i(stJumps[2]),
                "|q_jump_bp_e4=", _i(qJumps[2]), "|equil_recycle=", _u(equil0), "|bootstrap_recycle=", _u(bootstrapProfit), "|event1_st_recycle=",
                _u(stProfits[0]), "|steady_bp_yr_e4=", _u(steadyBpYrE4)
            )
        );
    }

    /**
     * @notice ST daily / quote weekly, D50, 2 full cycles. This cadence makes q* genuinely oscillate BELOW the
     *         peg (quote staleness accrues 0.82 bp/day for a week, then snaps back), so arbers sell ST down
     *         the dense band all week and buy it back at the weekly mark: REPEATABLE two-sided extraction.
     *         Cycle 2 (steady state) is annualized and asserted inside the design band ([0.4x, 2.5x] of the
     *         84 bp/yr estimate; measured ~53.1 bp/yr) AND above the 10 bp/yr nasty threshold — this test
     *         passes by proving the stale-quote cadence nasty.
     */
    function test_T2_RateStepArb_StDailyQuoteWeekly_RepeatableExtraction() public {
        uint256 bpYrA = _runWeeklyCadenceAtD50(0);
        uint256 bpYrD = _runWeeklyCadenceAtD50(1);
        _logPairedU("T2_ARB_st1d_q7d_bp_yr_e4", "drain=D50", bpYrA, bpYrD);
        _logVerdict("Q2_st_daily_quote_weekly", "nasty=true_both_tilts", string.concat("bp_yr_e4_tilt9999=", _u(bpYrA), "|tilt9010=", _u(bpYrD)));
    }

    /**
     * @notice Weekly-cadence measurement body for one tilt; snapshot-isolated. The quote-side band the arbers
     *         oscillate through is identical across tilts; tilt9010 adds ~0.53 bp of extra buy-side range up to
     *         its higher beta, so its extraction is expected slightly larger — both inside the pre-registered
     *         [0.4x, 2.5x] band of the 84 bp/yr design estimate and both above the 10 bp/yr nasty threshold.
     */
    function _runWeeklyCadenceAtD50(uint256 t) internal returns (uint256 bpYrE4) {
        (uint256 snap, uint256 snapTs) = _snapState();
        _usePool(t);
        _drainTo(2);
        uint256 equil0 = _arbToFeeEdge();
        uint256 tvl = _poolTvlAtFair();
        _setQuoteCadence(Q_STEP_7D, 7 days);

        uint256 week1;
        uint256 week2;
        int256 weeklyEventJump;
        uint256 qStaleE4;
        for (uint256 d = 1; d <= 14; ++d) {
            _warpTo(stMarkTs + 1 days - 1);
            bool weekly = d % 7 == 0;
            if (weekly) {
                qStaleE4 = (_fairQRate() * 1e18 / qMark - 1e18) / 1e10;
            }
            (int256 j, uint256 pr) = _runEvent(true, weekly);
            if (weekly) weeklyEventJump = j;
            if (d <= 7) week1 += pr;
            else week2 += pr;
        }

        assertApproxEqAbs(qStaleE4, 57_534, 200, "the weekly quote staleness component must be 5.7534 bp at the weekly mark");
        assertGt(week2, 0, "cycle-2 extraction must be strictly positive: the weekly q* oscillation is a repeatable arb");
        bpYrE4 = _bpE4(week2 * 52, tvl);
        // Pre-registered design band: annualized steady extraction within [0.4x, 2.5x] of the 84 bp/yr
        // estimate (measured: ~53.1 bp/yr on tilt9999), and the nasty classification itself is asserted.
        assertGe(bpYrE4, 336_000, "the weekly-cadence extraction must be at least 0.4x the 84 bp/yr design estimate");
        assertLe(bpYrE4, 2_100_000, "the weekly-cadence extraction must be at most 2.5x the 84 bp/yr design estimate");
        assertGt(bpYrE4, 100_000, "VERDICT: st-daily/quote-weekly extraction must exceed 10 bp/yr of TVL - this test passes by PROVING the cadence nasty");

        _restoreState(snap, snapTs);
        _logMetric(
            "T2_ARB",
            string.concat(
                "pool=", _tiltLabel(t), "|drain=D50|cadence=st1d_q7d|fee_bp_e4=10000|weekly_event_jump_bp_e4=", _i(weeklyEventJump),
                "|q_staleness_bp_e4=", _u(qStaleE4), "|equil_recycle=", _u(equil0), "|week1_profit=", _u(week1), "|week2_profit=", _u(week2),
                "|arb_bp_yr_e4=", _u(bpYrE4)
            )
        );
    }

    /**
     * @notice Cadence/fee breakeven in two measured regimes. STATIC pool (reframed per header deviation a):
     *         NO cadence sustains steady-state extraction — the pool rests at the prior q*-max fee edge and an
     *         identical sawtooth never re-opens it (including 24h at 1.5 bp fee); only the one-time recycle
     *         margin on fresh inventory scales with staleness (asserted monotone in the update interval).
     *         SUSTAINED FLOW (`_flowBreakevenSweep`): a 9-point cadence x fee grid of 0.2%/day-exit
     *         simulations measures where the breakeven really bites. The analytic breakeven interval is
     *         COMPUTED as fee / EXCESS_CARRY_PER_DAY (0.73 days at 1 bp) and cross-checked against the
     *         measured regime flip at every grid point: slower-than-breakeven updates let arbs strip the ST
     *         leg to beta every period (extraction = flow x (jump - fee): cadence- and fee-dependent), while
     *         faster-than-breakeven pools rest at the (1+jump)(1-fee) discount below the peg and leak only
     *         flow-impact crumbs — the fee never gates per-inventory extraction, it sets the resting discount.
     */
    function test_T2_BreakevenCadence_FeeVsUpdateInterval() public {
        uint256[4] memory event1A = _runStaticBreakevenGrid(0);
        uint256[4] memory event1D = _runStaticBreakevenGrid(1);
        string[4] memory labels = ["6h", "12h", "24h", "48h"];
        for (uint256 c = 0; c < 4; ++c) {
            _logPairedU("T2_BREAKEVEN_event1_recycle", string.concat("cadence=", labels[c], "|fee_bp_e4=10000"), event1A[c], event1D[c]);
        }
        uint256[9] memory bpYrA = _flowBreakevenSweep(0);
        uint256[9] memory bpYrD = _flowBreakevenSweep(1);
        string[9] memory flowLabels = ["6h@0.5bp", "12h@0.5bp", "24h@0.5bp", "6h@1bp", "12h@1bp", "24h@1bp", "48h@1bp", "24h@1.5bp", "48h@1.5bp"];
        for (uint256 k = 0; k < 9; ++k) {
            _logPairedU("T2_FLOWBREAKEVEN_steady_bp_yr_e4", string.concat("grid=", flowLabels[k]), bpYrA[k], bpYrD[k]);
        }
    }

    /// Static-pool breakeven grid for one tilt (own frame keeps the caller within via_ir stack limits).
    function _runStaticBreakevenGrid(uint256 t) internal returns (uint256[4] memory event1) {
        uint256[4] memory stSteps = [ST_STEP_6H, ST_STEP_12H, ST_STEP_1D, ST_STEP_2D];
        uint256[4] memory qSteps = [Q_STEP_6H, Q_STEP_12H, Q_STEP_1D, Q_STEP_2D];
        uint256[4] memory periods = [uint256(6 hours), 12 hours, 1 days, 2 days];
        string[4] memory labels = ["6h", "12h", "24h", "48h"];
        uint256[4] memory steady;

        for (uint256 c = 0; c < 4; ++c) {
            (uint256 snap, uint256 snapTs) = _snapState();
            _usePool(t);
            _drainTo(2);
            _arbToFeeEdge();
            _setStCadence(stSteps[c], periods[c]);
            _setQuoteCadence(qSteps[c], periods[c]);
            (, uint256[] memory profits,) = _runSyncEvents(3);
            event1[c] = profits[0];
            steady[c] = profits[2];
            _restoreState(snap, snapTs);
            assertLe(steady[c], DUST_PROFIT, "no cadence sustains steady-state extraction in a static pool (fee-edge resting + identical sawtooth)");
            _logMetric(
                "T2_BREAKEVEN",
                string.concat(
                    "pool=", _tiltLabel(t), "|cadence=", labels[c], "|fee_bp_e4=10000|event1_recycle=", _u(event1[c]), "|steady_event=", _u(steady[c])
                )
            );
        }
        assertLe(event1[0], event1[1], "the one-time recycle margin must be nondecreasing in the update interval (6h <= 12h)");
        assertLe(event1[1], event1[2], "the one-time recycle margin must be nondecreasing in the update interval (12h <= 24h)");
        assertLe(event1[2], event1[3], "the one-time recycle margin must be nondecreasing in the update interval (24h <= 48h)");
        assertGt(event1[3], event1[0], "a 48h staleness must recycle strictly more than a 6h staleness");

        // Fee variant: 1.5 bp fee, 24h cadence. Steady state is still zero — but so is it at 1 bp (see above);
        // the fee's real effect is a deeper resting discount, not steady-state protection.
        (uint256 snapFee, uint256 snapFeeTs) = _snapState();
        _usePool(t);
        _drainTo(2);
        vault.manualUnsafeSetStaticSwapFeePercentage(pool, 1.5e14);
        _arbToFeeEdge();
        (, uint256[] memory feeProfits,) = _runSyncEvents(3);
        assertLe(feeProfits[2], DUST_PROFIT, "a 1.5 bp fee at 24h cadence must show zero steady-state extraction as well");
        _restoreState(snapFee, snapFeeTs);
        _logMetric(
            "T2_BREAKEVEN",
            string.concat(
                "pool=", _tiltLabel(t), "|cadence=24h|fee_bp_e4=15000|event1_recycle=", _u(feeProfits[0]), "|steady_event=", _u(feeProfits[2])
            )
        );
    }

    /**
     * @notice Sustained-flow half of the breakeven test for one tilt (own frame keeps the caller within via_ir
     *         stack limits): 9 (cadence, fee) grid points, each a snapshot-isolated `_flowScenario`. Asserts
     *         the analytic regime classification (per-period jump vs fee) against FOUR independent measurements
     *         per point — extraction materiality, extraction magnitude vs the flow x (jump - fee) margin, the
     *         resting spot, and the end-state ST leg — then brackets the computed breakeven interval with the
     *         measured flips and asserts extraction monotone in staleness and antitone in the fee. The resting
     *         point of a supra-breakeven boundary arb is min(beta, (1+jump)(1-fee)): tilt9999's beta truncates
     *         it at every supra grid point (strip to dust), while tilt9010 (beta = 1 + 5.3e-5) is only
     *         truncated when (1+jump)(1-fee) >= beta — at 24h/0.5bp, 48h/1bp and 48h/1.5bp — and RETAINS
     *         inventory at the unpinned supra points (12h/0.5bp and 24h/1bp), resting at the analytic target.
     */
    function _flowBreakevenSweep(uint256 t) internal returns (uint256[9] memory bpYr) {
        uint256[9] memory stSteps =
            [ST_STEP_6H, ST_STEP_12H, ST_STEP_1D, ST_STEP_6H, ST_STEP_12H, ST_STEP_1D, ST_STEP_2D, ST_STEP_1D, ST_STEP_2D];
        uint256[9] memory qSteps = [Q_STEP_6H, Q_STEP_12H, Q_STEP_1D, Q_STEP_6H, Q_STEP_12H, Q_STEP_1D, Q_STEP_2D, Q_STEP_1D, Q_STEP_2D];
        uint256[9] memory periods = [uint256(6 hours), 12 hours, 1 days, 6 hours, 12 hours, 1 days, 2 days, 1 days, 2 days];
        uint256[9] memory fees = [uint256(5e13), 5e13, 5e13, 1e14, 1e14, 1e14, 1e14, 1.5e14, 1.5e14];
        string[9] memory labels = ["6h", "12h", "24h", "6h", "12h", "24h", "48h", "24h", "48h"];

        for (uint256 k = 0; k < 9; ++k) {
            (uint256 snap, uint256 snapTs) = _snapState();
            _usePool(t);
            (uint256 bpYrK, uint256 sProfit, uint256 spotEnd, uint256 stRawEnd) = _flowScenario(stSteps[k], qSteps[k], periods[k], fees[k]);
            _restoreState(snap, snapTs);
            bpYr[k] = bpYrK;

            uint256 jump = EXCESS_CARRY_PER_DAY * periods[k] / 1 days;
            bool supra = jump > fees[k];
            uint256 target = (1e18 + jump).mulDown(1e18 - fees[k]);
            bool pinned = supra && target >= _betaOf(t);
            uint256 analyticE4 = pinned ? FLOW_PCT * (jump - fees[k]) / 1e18 * 365 / 1e10 : 0;
            if (pinned) {
                assertGt(bpYrK, FLOW_MATERIAL_BP_YR_E4, "a slower-than-breakeven cadence with beta pinning must extract materially under flow");
                assertGe(bpYrK, analyticE4 * 3 / 10, "pinned supra-breakeven flow extraction must be at least 0.3x the flow x (jump - fee) margin");
                assertLe(bpYrK, analyticE4 * 3, "pinned supra-breakeven flow extraction must be at most 3x the flow x (jump - fee) margin");
                assertGt(spotEnd, 1e18, "a pinned supra-breakeven pool must rest above the peg after every boundary arb");
                assertLe(stRawEnd, 1e19, "a beta-pinned supra-breakeven boundary arb must strip the ST leg to dust");
            } else {
                // Sub-breakeven (jump < fee) OR supra-but-unpinned (tilt9010's beta headroom): the pool tracks
                // fair-minus-fee up to its resting target, exiters sell at ~fair prices, and the boundary arb
                // finds only flow-impact crumbs. The flow x (jump - fee) transfer (exiter haircut -> arber)
                // exists ONLY where beta caps the pool below fair — measured head-to-head at 12h/0.5bp and
                // 24h/1bp, where tilt9999 (pinned) extracts materially and tilt9010 (unpinned) does not.
                assertGt(sProfit, 0, "unpinned pools still leak the flow-impact crumb: the fee never fully gates per-inventory extraction");
                assertLe(bpYrK, FLOW_MATERIAL_BP_YR_E4, "an unpinned cadence/fee point must leak only immaterial flow-impact crumbs");
                assertApproxEqAbs(spotEnd, target, 5e12, "an unpinned pool must rest at its analytic (1+jump)(1-fee) spot");
                assertGt(stRawEnd, 1e22, "an unpinned pool must retain its ST inventory: the arb skims the flow, never strips the leg");
            }
            _logMetric(
                "T2_FLOWBREAKEVEN",
                string.concat(
                    "pool=", _tiltLabel(t), "|cadence=", labels[k], "|fee_bp_e4=", _u(fees[k] / 1e10), "|interval_days_e2=",
                    _u(periods[k] * 100 / 1 days), "|analytic_margin_bp_yr_e4=", _u(analyticE4), "|steady_profit=", _u(sProfit),
                    "|steady_bp_yr_e4=", _u(bpYrK), "|spot_end=", _u(spotEnd), "|st_raw_end=", _u(stRawEnd), "|regime=",
                    supra ? (pinned ? "supra_pinned" : "supra_unpinned") : "sub"
                )
            );
        }

        // The computed breakeven interval (fee / EXCESS_CARRY_PER_DAY, in days*100) must fall inside the
        // measured regime-flip bracket at every fee — this is the cross-check that replaces any prose figure.
        // (For tilt9999 the breakeven IS the extraction-materiality flip because every supra point is
        // beta-pinned; for tilt9010 materiality additionally requires (1+jump)(1-fee) >= beta, verified by
        // the per-point pinned/unpinned assertions above.)
        uint256 be05 = uint256(5e13) * 100 / EXCESS_CARRY_PER_DAY;
        uint256 be10 = uint256(1e14) * 100 / EXCESS_CARRY_PER_DAY;
        uint256 be15 = uint256(1.5e14) * 100 / EXCESS_CARRY_PER_DAY;
        assertGt(be05, 25, "the computed 0.5 bp breakeven (0.36 days) must exceed the measured-sub 6h grid point");
        assertLt(be05, 50, "the computed 0.5 bp breakeven (0.36 days) must undercut the measured-supra 12h grid point");
        assertGt(be10, 50, "the computed 1 bp breakeven (0.73 days) must exceed the measured-sub 12h grid point");
        assertLt(be10, 100, "the computed 1 bp breakeven (0.73 days) must undercut the measured-supra 24h grid point");
        assertGt(be15, 100, "the computed 1.5 bp breakeven (1.10 days) must exceed the measured-sub 24h grid point");
        assertLt(be15, 200, "the computed 1.5 bp breakeven (1.10 days) must undercut the measured-supra 48h grid point");

        // Extraction monotone in staleness at 1 bp (crumb-noise slack below the materiality floor) and
        // antitone in the fee at 24h.
        assertLe(bpYr[3], bpYr[4] + FLOW_MATERIAL_BP_YR_E4, "flow extraction must be nondecreasing in the update interval (6h <= 12h at 1 bp)");
        assertLe(bpYr[4], bpYr[5] + FLOW_MATERIAL_BP_YR_E4, "flow extraction must be nondecreasing in the update interval (12h <= 24h at 1 bp)");
        assertLe(bpYr[5], bpYr[6] + FLOW_MATERIAL_BP_YR_E4, "flow extraction must be nondecreasing in the update interval (24h <= 48h at 1 bp)");
        assertGt(bpYr[6], bpYr[3] + FLOW_MATERIAL_BP_YR_E4, "48h updates at 1 bp must extract strictly more than 6h updates");
        assertGe(bpYr[2] + FLOW_MATERIAL_BP_YR_E4, bpYr[5], "flow extraction at 24h must be nonincreasing in the fee (0.5 bp >= 1 bp)");
        assertGe(bpYr[5] + FLOW_MATERIAL_BP_YR_E4, bpYr[7], "flow extraction at 24h must be nonincreasing in the fee (1 bp >= 1.5 bp)");
        assertGt(bpYr[2], bpYr[7] + FLOW_MATERIAL_BP_YR_E4, "a 0.5 bp fee at 24h must leak strictly more than a 1.5 bp fee");

        // The breakeven interval itself is tilt-independent (fee vs drift arithmetic): log it once.
        if (t == 0) {
            _logVerdict(
                "Q2_breakeven_cadence_vs_fee",
                "breakeven=fee_div_excess_drift_both_tilts",
                string.concat(
                    "days_e2_at_0.5bp=", _u(be05), "|days_e2_at_1bp=", _u(be10), "|days_e2_at_1.5bp=", _u(be15),
                    "|sub_breakeven_leak=impact_crumbs_only"
                )
            );
        }
    }

    /**
     * @notice Standing-discount arb with NO rate steps: isolates the fair-at-NAV discount of a drained pool
     *         from the T2 step effects. One-time recycling flow: arbs refill the pool to the fee edge — this is
     *         why drain states are transient and why the year sim's drain is endogenously capped near the edge.
     */
    function test_T2_StandingDiscountArb_AtDrainStates() public {
        for (uint256 i = 0; i < 5; ++i) {
            uint256 pA = _runStandingDiscountAtAnchor(0, i);
            uint256 pD = _runStandingDiscountAtAnchor(1, i);
            // Cross-tilt invariance: the buy-back crosses the SAME price interval on both tilts (the tilts'
            // ST legs differ by a constant offset that cancels in the swap), so the profits pair near-equal.
            _logPairedU("T2_DISCOUNT_arb_profit", string.concat("drain=", _anchorLabel(i)), pA, pD);
        }
    }

    /// Standing-discount measurement body for one (tilt, anchor); snapshot-isolated, NO rate steps.
    function _runStandingDiscountAtAnchor(uint256 t, uint256 i) internal returns (uint256 profit) {
        (uint256 snap, uint256 snapTs) = _snapState();
        _usePool(t);
        _drainTo(i);
        uint256 preSpot = _spotPrice();
        uint256 tvl = _poolTvlAtFair();
        profit = _arbToFeeEdge();
        uint256 postSpot = _spotPrice();

        if (i == 0) {
            assertLe(profit, DUST_PROFIT, "at the balance point the pool is at fair and the fee blocks any arb");
        } else if (i == 1) {
            assertLe(_bpE4(profit, tvl), 5_000, "the D25 standing discount (1.22 bp) barely exceeds the 1 bp fee: profit < 0.5 bp of TVL");
        } else {
            assertGt(profit, 0, "a drained pool below the fee edge must offer a positive standing buy-ST arb at fair-at-NAV valuation");
            assertGe(postSpot, 1e18 - 1e14 - 1e13, "the standing arb must run the spot up to the buy-side fee edge (1 - fee, -0.1 bp slack)");
            assertLe(postSpot, 1e18 - 1e14 + 1e13, "the standing arb must stop at the buy-side fee edge (1 - fee, +0.1 bp slack)");
        }
        _restoreState(snap, snapTs);
        _logMetric(
            "T2_DISCOUNT",
            string.concat(
                "pool=", _tiltLabel(t), "|drain=", _anchorLabel(i), "|pre_spot=", _u(preSpot), "|discount_bp_e4=", _u((1e18 - preSpot) / 1e10),
                "|arb_profit=", _u(profit), "|arb_profit_bp_tvl_e4=", _u(_bpE4(profit, tvl)), "|post_spot=", _u(postSpot)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                        T3 — SINGLE-SIDED STABLE LP (Q3)
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice One-way single-sided quote add across drain anchors and sizes {0.1%, 1%, 5% of fair TVL},
     *         HEAD-TO-HEAD. tilt9999 at the balance point is ~proportional: fair cost < 0.1 bp for every size.
     *         tilt9010 at the balance point carries a REAL 10% ST slice, so its add pays the fee on that
     *         taxable share (~0.1 bp) — asserted against the same [0.3x, 3x] fee+impact model band used at the
     *         drained anchors (per-tilt ST shares from the derivation). The FAIR-valued cost is logged
     *         (negative at drained states: joining a discounted pool at NAV is a subsidy — header deviation e).
     */
    function test_T3_SingleSidedStableAdd_OneWayCost_AcrossDrainStatesAndSizes() public {
        uint256[3] memory sizePctWad = [uint256(1e15), 1e16, 5e16];
        for (uint256 i = 0; i < 5; ++i) {
            int256[3] memory costA = _runAddCostsAtAnchor(0, i, sizePctWad);
            int256[3] memory costD = _runAddCostsAtAnchor(1, i, sizePctWad);
            for (uint256 sIdx = 0; sIdx < 3; ++sIdx) {
                _logPaired(
                    "T3_ADD_cost_spot_bp_e4",
                    string.concat("drain=", _anchorLabel(i), "|size_pct_e4=", _u(sizePctWad[sIdx] / 1e12)),
                    costA[sIdx],
                    costD[sIdx]
                );
            }
        }
    }

    /// Add-cost measurement body for one (tilt, anchor) across the three sizes; snapshot-isolated.
    function _runAddCostsAtAnchor(uint256 t, uint256 i, uint256[3] memory sizePctWad) internal returns (int256[3] memory costSpots) {
        (uint256 snapOuter, uint256 snapOuterTs) = _snapState();
        _usePool(t);
        _drainTo(i);
        int256 prevCostSpot = type(int256).min;
        for (uint256 sIdx = 0; sIdx < 3; ++sIdx) {
            (uint256 snapInner, uint256 snapInnerTs) = _snapState();
            uint256 size = _poolTvlAtFair().mulDown(sizePctWad[sIdx]);
            uint256 model = _addCostModelBpE4(i, size);
            (int256 costFair, int256 costSpot, uint256 bptOut) = _singleSidedAdd(size);
            costSpots[sIdx] = costSpot;

            if (i == 0 && t == 0) {
                assertLt(costFair, 1_000, "a single-sided quote add at the 99.99%-stable balance point must cost < 0.1 bp at fair");
                assertGt(costFair, -1_000, "the balance-point add cost cannot be meaningfully negative (spot == fair at the peg)");
            } else {
                assertGe(costSpot, int256(model * 3 / 10), "the spot-numeraire add cost must be at least 0.3x the fee+impact model");
                assertLe(costSpot, int256(model * 3), "the spot-numeraire add cost must be at most 3x the fee+impact model");
                // The fee component DROPS slightly with size (the add lifts the price toward the peg,
                // shrinking the taxable ST share) while the impact term grows; allow that bounded
                // countervailing drift (0.02 bp) so only impact-scale violations fail.
                if (sIdx > 0 && prevCostSpot != type(int256).min) {
                    assertGe(costSpot, prevCostSpot - 200, "the spot-numeraire add cost must be nondecreasing in size beyond composition drift");
                }
                prevCostSpot = costSpot;
            }
            _restoreState(snapInner, snapInnerTs);
            _logMetric(
                "T3_ADD",
                string.concat(
                    "pool=", _tiltLabel(t), "|drain=", _anchorLabel(i), "|size_pct_e4=", _u(sizePctWad[sIdx] / 1e12), "|bpt_out=", _u(bptOut),
                    "|addCost_fair_bp_e4=", _i(costFair), "|addCost_spot_bp_e4=", _i(costSpot), "|model_bp_e4=", _u(model)
                )
            );
        }
        _restoreState(snapOuter, snapOuterTs);
    }

    /**
     * @notice Round-trip cost (add unbalanced quote, remove single-token quote) at 1% of TVL per anchor —
     *         numeraire-clean (quote in vs quote out). Verdict input: balance-point round trip must be < 5 bp.
     */
    function test_T3_SingleSidedStableRoundTrip_CostAcrossDrainStates() public {
        int256 d0A;
        int256 d0D;
        for (uint256 i = 0; i < 5; ++i) {
            int256 rtA = _runRoundTripAtAnchor(0, i);
            int256 rtD = _runRoundTripAtAnchor(1, i);
            if (i == 0) (d0A, d0D) = (rtA, rtD);
            _logPaired("T3_ROUNDTRIP_bp_e4", string.concat("drain=", _anchorLabel(i)), rtA, rtD);
        }
        _logVerdict(
            "Q3_round_trip",
            "meaningful_loss=false_both_tilts",
            string.concat("balance_point_roundTrip_bp_e4_tilt9999=", _i(d0A), "|tilt9010=", _i(d0D))
        );
    }

    /// Round-trip measurement body (add unbalanced quote, remove single-token quote) for one (tilt, anchor).
    function _runRoundTripAtAnchor(uint256 t, uint256 i) internal returns (int256 roundTripE4) {
        (uint256 snap, uint256 snapTs) = _snapState();
        _usePool(t);
        _drainTo(i);
        uint256 size = _poolTvlAtFair().mulDown(1e16);
        (, int256 costSpot, uint256 bptOut) = _singleSidedAdd(size);
        uint256 qOut = router.removeLiquiditySingleTokenExactIn(pool, lp, bptOut, _tokens(), 1, 0);
        roundTripE4 = (int256(size) - int256(qOut)) * 1e8 / int256(size);

        assertGt(roundTripE4, 0, "the round trip must cost strictly more than zero (pool-favoring rounding; negative means free extraction)");
        int256 oneWay = costSpot > 0 ? costSpot : int256(0);
        assertLe(roundTripE4, 2 * oneWay + 10_000, "the round trip must not exceed twice the one-way cost plus 1 bp of fee/rounding slack");
        if (i == 0) {
            assertLt(roundTripE4, 50_000, "VERDICT input: the balance-point round trip must cost < 5 bp");
        }
        _restoreState(snap, snapTs);
        _logMetric(
            "T3_ROUNDTRIP",
            string.concat(
                "pool=", _tiltLabel(t), "|drain=", _anchorLabel(i), "|oneWay_spot_bp_e4=", _i(costSpot), "|roundTrip_bp_e4=", _i(roundTripE4)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                      T4 — WIRING, EDGES, NUMERICS (Q4 SUPPORT)
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Quote leg registered STANDARD (production wiring) while the quote asset truly yields 3%: the
     *         scaled fair price drifts down ~0.822 bp/day with no reset, arbs sell ST into the pool all the
     *         way to alpha, and the pool dies as exit liquidity in ~3 weeks (analytic 18-19 days; <= 22
     *         asserted with slack for the fee-edge offset).
     */
    function test_T4_QuoteRegisteredStandard_PoolDiesInThreeWeeks() public {
        uint256 deadA = _runStandardWiring(0);
        uint256 deadD = _runStandardWiring(1);
        _logPairedU("T4_WIRING_dead_day", "", deadA, deadD);
        _logVerdict("Q4_quote_standard_wiring", "broken=true_both_tilts", string.concat("dead_day_tilt9999=", _u(deadA), "|tilt9010=", _u(deadD)));
    }

    /**
     * @notice STANDARD-quote band-exit body for one tilt; snapshot-isolated. Both tilts share alpha (the band
     *         floor), so the ~0.822 bp/day of unreset quote drift kills either pool on the same ~18-19 day
     *         analytic schedule; tilt9010's extra beta headroom is on the WRONG side (above peg) to help.
     */
    function _runStandardWiring(uint256 t) internal returns (uint256 deadDay) {
        (uint256 snap, uint256 snapTs) = _snapState();
        pool = _createPool(t == 0 ? _eclpParamsA() : _eclpParamsD(), t == 0 ? _derivedParamsA() : _derivedParamsD(), true, bytes32(uint256(10 + t)));
        tilt = t;
        router.initialize(pool, address(this), _tokens(), _two(_x0Of(t), Y0));
        quoteLegStandard = true;

        for (uint256 d = 1; d <= 30; ++d) {
            _warpTo(stMarkTs + 1 days);
            _stepStOracle();
            _stepQuoteOracle(); // fair bookkeeping only: the pool has no quote provider, its oracle rate is pinned at 1
            _arbToFeeEdge();
            uint256 share = _stableShare();
            if (deadDay == 0 && share < 1e16) deadDay = d;
            _logMetric(
                "T4_WIRING", string.concat("pool=", _tiltLabel(t), "|day=", _u(d), "|spot=", _u(_spotPrice()), "|stable_share_e18=", _u(share))
            );
        }

        assertGt(deadDay, 0, "the STANDARD-quote pool must lose >99% of its stables within the 30-day window");
        assertLe(deadDay, 22, "the STANDARD-quote pool must die within ~3 weeks (analytic 18-19 days at 0.822 bp/day of unreset drift)");
        assertLt(_stableShare(), 1e16, "the STANDARD-quote pool must end with < 1% stable share");
        vm.expectRevert(GyroECLPMath.AssetBoundsExceeded.selector);
        router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), 1e18, 0);
        _restoreState(snap, snapTs);
        quoteLegStandard = false;
    }

    /**
     * @notice One-way-ness of the peg, HEAD-TO-HEAD: at the balance point the buy side holds ~0.01% of TVL in
     *         ST on tilt9999 but ~10.00% on tilt9010 (each all-buyable in one shot, then hard reverts) — the
     *         re-tilt is exactly what makes the pool one-way. The sell side fills a 1M (10% of stables) exit
     *         in a single swap at a ~fee+impact haircut on BOTH tilts (quote-side geometry is shared).
     */
    function test_T4_PegIsOneWayExitLiquidity_BuySideInventoryCapped() public {
        (uint256 buyBpA, uint256 hcA) = _runOneWayEdge(0);
        (uint256 buyBpD, uint256 hcD) = _runOneWayEdge(1);
        assertApproxEqAbs(buyBpA, 10_000, 100, "tilt9999 must hold ~1.0001 bp of TVL in buyable ST at the balance point");
        assertApproxEqAbs(buyBpD, 10_000_000, 10_000, "tilt9010 must hold ~10.00% of TVL in buyable ST at the balance point");
        _logPairedU("T4_EDGE_max_buyable_bp_tvl_e4", "", buyBpA, buyBpD);
        _logPairedU("T4_EDGE_one_shot_exit_1M_haircut_bp_e4", "", hcA, hcD);
    }

    /// One-way edge body for one tilt; snapshot-isolated.
    function _runOneWayEdge(uint256 t) internal returns (uint256 buyableBpTvlE4, uint256 haircutE4) {
        (uint256 snapOuter, uint256 snapOuterTs) = _snapState();
        _usePool(t);
        (uint256 xRaw,) = _rawBalances();
        uint256 tvl = _poolTvlAtFair();
        buyableBpTvlE4 = _bpE4(xRaw, tvl);

        (uint256 snap, uint256 snapTs) = _snapState();
        // Exact-out of the FULL leg trips the (pool-favoring) asset-bound rounding at the corner; all but a
        // 1e12-wei (1e-6 token) dust margin is the economically complete buy.
        router.swapExactOut(pool, arber, IERC20(address(quoteToken)), IERC20(address(st)), xRaw - 1e12, type(uint256).max);
        (uint256 xAfter,) = _rawBalances();
        assertLe(xAfter, 1e12, "buying the entire ST leg (minus corner-rounding dust) exact-out must succeed at the balance point");
        vm.expectRevert(GyroECLPMath.AssetBoundsExceeded.selector);
        router.swapExactIn(pool, arber, IERC20(address(quoteToken)), IERC20(address(st)), 1e18, 0);
        _restoreState(snap, snapTs);

        vm.expectRevert(GyroECLPMath.AssetBoundsExceeded.selector);
        router.swapExactOut(pool, arber, IERC20(address(quoteToken)), IERC20(address(st)), xRaw + 1e18, type(uint256).max);

        uint256 sellAmt = 1_000_000e18;
        uint256 qOut = router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), sellAmt, 0);
        haircutE4 = _bpE4(sellAmt - qOut, sellAmt); // rates are 1e18: raw == fair
        assertGe(haircutE4, 10_000, "a 1M one-shot exit must pay at least the 1 bp swap fee");
        assertLe(haircutE4, 20_000, "a 1M one-shot exit (10% of stables) must cost at most fee + ~0.5 bp of near-peg impact + slack");
        _restoreState(snapOuter, snapOuterTs);
        _logMetric(
            "T4_EDGE",
            string.concat(
                "pool=", _tiltLabel(t), "|max_buyable_st=", _u(xRaw), "|max_buyable_bp_tvl_e4=", _u(buyableBpTvlE4),
                "|one_shot_exit_1M_haircut_bp_e4=", _u(haircutE4)
            )
        );
    }

    /**
     * @notice Min-trade and rounding behavior near the tilt with the production 1e6 scaled18 minimum: dust
     *         sells below the post-fee minimum revert, dust buys below the minimum calculated amount revert,
     *         and a 10k ST->quote->ST round trip at D50 leaks ~2x fee with wei-scale rounding (pool-favoring,
     *         no rebate path). Header deviation c documents the 2e6/EXACT_OUT reformulation.
     */
    function test_T4_MinTradeAndRounding_NearTilt() public {
        uint256 leakA = _runMinTradeAndRounding(0);
        uint256 leakD = _runMinTradeAndRounding(1);
        _logPairedU("T4_EDGE_d50_roundtrip_10k_leak_bp_e4", "", leakA, leakD);
    }

    /// Min-trade/rounding body for one tilt; snapshot-isolated (identical expectations: shared geometry).
    function _runMinTradeAndRounding(uint256 t) internal returns (uint256 leakE4) {
        (uint256 snap, uint256 snapTs) = _snapState();
        _usePool(t);
        uint256 out = router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), 2e6, 0);
        assertGt(out, 0, "a 2e6-wei ST sell must clear the 1e6 scaled18 min-trade after the fee cut");

        vm.expectRevert(IVaultErrors.TradeAmountTooSmall.selector);
        router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), 1e5, 0);

        vm.expectRevert(IVaultErrors.TradeAmountTooSmall.selector);
        router.swapExactOut(pool, exiter, IERC20(address(quoteToken)), IERC20(address(st)), 9e5, type(uint256).max);

        _drainTo(2);
        uint256 stIn = 10_000e18;
        uint256 qMid = router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), stIn, 0);
        uint256 stBack = router.swapExactIn(pool, exiter, IERC20(address(quoteToken)), IERC20(address(st)), qMid, 0);
        assertLt(stBack, stIn, "a round-trip swap must return strictly less than sent");
        leakE4 = _bpE4(stIn - stBack, stIn);
        assertGe(leakE4, 18_000, "the round-trip leak must be at least 2x fee - 0.2 bp (no rebate path exists)");
        assertLe(leakE4, 25_000, "the round-trip leak must be at most 2x fee + impact + 0.2 bp (rounding is wei-scale)");
        _restoreState(snap, snapTs);
        _logMetric(
            "T4_EDGE", string.concat("pool=", _tiltLabel(t), "|dust_sell_2e6_out=", _u(out), "|d50_roundtrip_10k_leak_bp_e4=", _u(leakE4))
        );
    }

    /**
     * @notice Numerics soak: 365 daily synchronized steps with a small daily exit flow (0.05% of TVL) and the
     *         arb loop keeps the pool functional through 8%/3% of accumulated rate scaling — no reverts, spot
     *         inside the band at the fee-edge resting point, and a fresh 1% single-sided add still ~free.
     */
    function test_T4_Numerics_YearOfDailyRateGrowth_PoolRemainsFunctional() public {
        (uint256 spotA, int256 addA) = _runNumericsYear(0);
        (uint256 spotD, int256 addD) = _runNumericsYear(1);
        _logPairedU("T4_EDGE_numerics_final_spot", "", spotA, spotD);
        _logPaired("T4_EDGE_numerics_final_add_cost_spot_bp_e4", "", addA, addD);
    }

    /// Numerics-soak body for one tilt; snapshot-isolated (365 daily steps with 0.05% exit flow + arb).
    function _runNumericsYear(uint256 t) internal returns (uint256 finalSpot, int256 costSpot) {
        (uint256 snap, uint256 snapTs) = _snapState();
        _usePool(t);
        for (uint256 d = 1; d <= 365; ++d) {
            _warpTo(stMarkTs + 1 days - 1);
            uint256 stAmt = _poolTvlAtFair().mulDown(5e14) * 1e18 / _fairStRate();
            router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), stAmt, 0);
            _arbToFeeEdge();
            _warpBy(1);
            _stepStOracle();
            _stepQuoteOracle();
        }

        finalSpot = _spotPrice();
        assertGe(finalSpot, 1e18 - 1e14 - 2e13, "after a year of daily steps the pool must rest no deeper than the fee edge (1 - fee - 0.2 bp)");
        assertLe(finalSpot, _betaOf(t), "the pool spot must stay inside the band at beta after a year of rate growth");
        assertApproxEqAbs(stMark, 1_083_277_000_000_000_000, 5e14, "the compounded daily ST rate must land on (1+0.08/365)^365 ~ 1.083277");
        assertApproxEqAbs(qMark, 1_030_453_000_000_000_000, 5e14, "the compounded daily quote rate must land on (1+0.03/365)^365 ~ 1.030453");

        uint256 size = _poolTvlAtFair().mulDown(1e16);
        uint256 stableShare = _stableShare();
        (uint256 stMarkEnd, uint256 qMarkEnd) = (stMark, qMark);
        (, costSpot,) = _singleSidedAdd(size);
        assertLt(costSpot, 10_000, "a fresh 1% single-sided add after a year must still cost < 1 bp (near-peg resting point)");
        _restoreState(snap, snapTs);
        _logMetric(
            "T4_EDGE",
            string.concat(
                "pool=", _tiltLabel(t), "|final_spot=", _u(finalSpot), "|final_st_rate=", _u(stMarkEnd), "|final_q_rate=", _u(qMarkEnd),
                "|final_stable_share_e18=", _u(stableShare), "|final_add_cost_spot_bp_e4=", _i(costSpot)
            )
        );
    }

    /**
     * @notice Intraday drift is an exiter haircut, not an LP leak: an identical ST exit at update-minus-1s
     *         pays ~1.37 bp more than at update-plus-1s (the accrued daily drift, which accrues to LPs).
     */
    function test_T4_IntradayDrift_ExiterHaircutBoundedByDailyDrift() public {
        uint256 dcA = _runIntradayDrift(0);
        uint256 dcD = _runIntradayDrift(1);
        _logPairedU("T4_EDGE_drift_capture_bp_e4", "", dcA, dcD);
    }

    /// Intraday-drift body for one tilt; snapshot-isolated (identical 1.3699 bp expectation: shared drift).
    function _runIntradayDrift(uint256 t) internal returns (uint256 driftCaptureE4) {
        (uint256 snapOuter, uint256 snapOuterTs) = _snapState();
        _usePool(t);
        uint256 stAmt = 10_000e18;

        (uint256 snap, uint256 snapTs) = _snapState();
        _warpTo(stMarkTs + 1 days - 1);
        uint256 fairInPre = stAmt.mulDown(_fairStRate());
        uint256 qOutPre = router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), stAmt, 0);
        uint256 haircutPreE4 = _bpE4(fairInPre - qOutPre.mulDown(_fairQRate()), fairInPre);
        _restoreState(snap, snapTs);

        _warpTo(stMarkTs + 1 days);
        _stepStOracle();
        _stepQuoteOracle();
        _warpBy(1);
        uint256 fairInPost = stAmt.mulDown(_fairStRate());
        uint256 qOutPost = router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), stAmt, 0);
        uint256 haircutPostE4 = _bpE4(fairInPost - qOutPost.mulDown(_fairQRate()), fairInPost);

        assertGt(haircutPreE4, haircutPostE4, "the pre-update seller must receive less: the accrued drift is an extra exit haircut");
        assertApproxEqAbs(
            int256(haircutPreE4) - int256(haircutPostE4),
            int256(13_699),
            2_000,
            "the haircut difference must equal the accrued daily drift (1.3699 bp, +-0.2 bp of price-impact slack)"
        );
        driftCaptureE4 = haircutPreE4 - haircutPostE4;
        _restoreState(snapOuter, snapOuterTs);
        _logMetric(
            "T4_EDGE",
            string.concat(
                "pool=", _tiltLabel(t), "|haircut_pre_bp_e4=", _u(haircutPreE4), "|haircut_post_bp_e4=", _u(haircutPostE4),
                "|drift_capture_bp_e4=", _u(driftCaptureE4)
            )
        );
    }
}

/**
 * @title Test_YearSimulation_ECLPExitLiquidity
 * @notice The 365-day single-sided-LP simulation (own contract so forge parallelizes it against the statics).
 *         Daily loop: exit flow at midday (0.2% of TVL, one 3%/day stress week), optimal arb to the fee edge
 *         just before the synchronized daily marks, then the rate steps. Every flow is ledgered at external
 *         fair rates and the LP's outcome vs holding the 3% stable is decomposed into exiter-haircut income,
 *         arb losses, excess ST carry and entry/exit mechanics — the ledger must close to within 1 bp of the
 *         deposit, and the verdict thresholds (LP loss > 5 bp/yr, arb extraction > 10 bp/yr) are asserted.
 */
contract Test_YearSimulation_ECLPExitLiquidity is ECLPExitLiquidityBase {
    using FixedPoint for uint256;

    /// Year-sim results carried out of the snapshot-isolated per-tilt run for paired reporting.
    struct SimRes {
        uint256 lpFinal;
        uint256 benchmark;
        int256 lpExcessBpE4;
        int256 transferSum;
        uint256 arbSum;
        uint256 carrySum;
        uint256 addCost;
        uint256 removeCost;
        int256 residual;
        uint256 avgTvl;
        uint256 arbBpYrE4;
        uint256 avgStShareE4;
        uint256 maxStShareE4;
        uint256 clampedDays;
    }

    /// One-year LP economics vs the 3%-stable-hold benchmark under sync daily updates with real exit flow,
    /// run head-to-head on both tilts (tilt9010's retained ST inventory earns the 5%/yr excess carry the
    /// 99.99 tilt strips away — the decisive Q3 contrast).
    function test_T3_LPOneYear_SyncDailyUpdates_VsStableHoldBenchmark() public {
        SimRes memory a = _runYearSim(0);
        SimRes memory d = _runYearSim(1);

        _logPaired("SIM_lpExcess_bp_e4", "", a.lpExcessBpE4, d.lpExcessBpE4);
        _logPairedU("SIM_arb_bp_yr_e4", "", a.arbBpYrE4, d.arbBpYrE4);
        _logPairedU("SIM_excess_carry", "", a.carrySum, d.carrySum);
        _logPaired("SIM_exiter_transfer", "", a.transferSum, d.transferSum);
        _logPairedU("SIM_avg_st_share_bp_e4", "", a.avgStShareE4, d.avgStShareE4);
        _logVerdict(
            "Q3_lp_loss",
            (a.lpExcessBpE4 >= -50_000 && d.lpExcessBpE4 >= -50_000) ? "meaningful=no_both_tilts" : "meaningful=yes",
            string.concat("lpExcess_bp_e4_tilt9999=", _i(a.lpExcessBpE4), "|tilt9010=", _i(d.lpExcessBpE4))
        );
        _logVerdict(
            "Q2_nasty_arbs_with_flow",
            (a.arbBpYrE4 > 100_000 || d.arbBpYrE4 > 100_000) ? "nasty=true" : "nasty=false_both_tilts",
            string.concat("arb_bp_yr_e4_tilt9999=", _u(a.arbBpYrE4), "|tilt9010=", _u(d.arbBpYrE4))
        );
    }

    /// 365-day simulation body for one tilt; snapshot-isolated. Asserts the ledger closure and both verdict
    /// thresholds per tilt with the tilt's own measured decomposition.
    function _runYearSim(uint256 t) internal returns (SimRes memory res) {
        (uint256 snap, uint256 snapTs) = _snapState();
        _usePool(t);
        uint256 deposit = 100_000e18;
        (, uint256 bpt) = router.addLiquidityUnbalanced(pool, lp, _tokens(), _two(0, deposit), 0);
        res.addCost = deposit.mulDown(_fairQRate()) - _bptFairValue(bpt);
        uint256 lpShareWad = bpt * 1e18 / IERC20(pool).totalSupply();

        uint256 sumTvl;
        for (uint256 d = 1; d <= 365; ++d) {
            _warpTo(stMarkTs + 12 hours);
            uint256 pct = (d >= 180 && d <= 186) ? 3e16 : 2e15;
            uint256 stAmt = _poolTvlAtFair().mulDown(pct) * 1e18 / _fairStRate();
            try router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), stAmt, 0) returns (uint256 qOut) {
                res.transferSum += int256(stAmt.mulDown(_fairStRate())) - int256(qOut.mulDown(_fairQRate()));
            } catch {
                res.clampedDays++;
            }
            uint256 stShareE4 = _stValueShareBpE4();
            if (stShareE4 > res.maxStShareE4) res.maxStShareE4 = stShareE4;
            res.avgStShareE4 += stShareE4;
            (uint256 stRawA,) = _rawBalances();
            uint256 carryA = stRawA.mulDown(_fairStRate());

            _warpTo(stMarkTs + 1 days - 1);
            res.arbSum += _arbToFeeEdge();
            (uint256 stRawB,) = _rawBalances();
            uint256 carryB = stRawB.mulDown(_fairStRate());
            // ST held ~half the day at the post-exit level and ~half at the post-arb level (trapezoid).
            res.carrySum += lpShareWad.mulDown((carryA + carryB) / 2).mulDown(EXCESS_CARRY_PER_DAY);
            sumTvl += _poolTvlAtFair();

            _warpBy(1);
            _stepStOracle();
            _stepQuoteOracle();
        }
        res.avgStShareE4 /= 365;

        uint256 bptValPre = _bptFairValue(bpt);
        uint256[] memory outs = router.removeLiquidityProportional(pool, lp, bpt, _tokens());
        res.lpFinal = _valueAtFair(outs[0], outs[1]);
        res.removeCost = bptValPre > res.lpFinal ? bptValPre - res.lpFinal : 0;
        res.benchmark = deposit.mulDown(_fairQRate());

        int256 lpExcess = int256(res.lpFinal) - int256(res.benchmark);
        res.lpExcessBpE4 = lpExcess * 1e8 / int256(res.benchmark);
        int256 explained = (res.transferSum - int256(res.arbSum)) * int256(lpShareWad) / 1e18 + int256(res.carrySum) - int256(res.addCost)
            - int256(res.removeCost);
        res.residual = lpExcess - explained;
        res.avgTvl = sumTvl / 365;
        res.arbBpYrE4 = _bpE4(res.arbSum, res.avgTvl);

        assertLe(
            res.residual >= 0 ? res.residual : -res.residual,
            int256(deposit / 1e4),
            "the fair-value ledger must close to within 1 bp of the deposit"
        );
        assertGe(res.lpExcessBpE4, -50_000, "VERDICT: the single-sided stable LP must not lose more than 5 bp/yr vs holding the 3% stable");
        assertLe(res.arbBpYrE4, 100_000, "VERDICT: total arb extraction under sync daily updates with real flow must stay under 10 bp/yr of TVL");
        assertEq(res.clampedDays, 0, "no exit-flow day should be clamped by the band: daily arb recycling restores depth");
        _restoreState(snap, snapTs);

        _logMetric(
            "SIM",
            string.concat(
                "pool=", _tiltLabel(t), "|lp_final=", _u(res.lpFinal), "|benchmark=", _u(res.benchmark), "|lpExcess_bp_e4=", _i(res.lpExcessBpE4),
                "|deposit=", _u(deposit), "|lp_share_e18=", _u(lpShareWad)
            )
        );
        _logMetric(
            "SIM",
            string.concat(
                "pool=", _tiltLabel(t), "|exiter_transfer=", _i(res.transferSum), "|arber_profit=", _u(res.arbSum), "|excess_carry=",
                _u(res.carrySum), "|entry_cost=", _u(res.addCost), "|exit_cost=", _u(res.removeCost), "|residual=", _i(res.residual)
            )
        );
        _logMetric(
            "SIM",
            string.concat(
                "pool=", _tiltLabel(t), "|arb_bp_yr_e4=", _u(res.arbBpYrE4), "|avg_tvl=", _u(res.avgTvl), "|avg_st_share_bp_e4=",
                _u(res.avgStShareE4), "|max_st_share_bp_e4=", _u(res.maxStShareE4), "|clamped_days=", _u(res.clampedDays)
            )
        );
    }
}

/**
 * @title Test_WhaleAddAndGenesis_ECLPExitLiquidity
 * @notice T5 "whale add" and T6 "one-sided genesis" scenarios, HEAD-TO-HEAD on both tilts (own contract so
 *         forge parallelizes them against the battery). Fresh salt-distinct pools per case; every PnL valued
 *         at the external fair rates (both 1.0 here — no oracle steps run in these scenarios).
 *
 *         T5: a $500k balance-point pool absorbs single-sided stablecoin adds up to 4x its TVL. Every offline
 *         invariant-math prediction (predict_scenarios.py, same 100-digit machinery as the pool derivation) is
 *         asserted against the measured chain values: slippage is sub-0.1 bp at EVERY size on both tilts, and
 *         the per-dollar cost FALLS with size — the E-CLP band caps the implicit-buy premium at beta - 1 and a
 *         larger whale owns a larger pro-rata share of the very fees he pays, so the naive "2x TVL must move
 *         the market" convexity intuition INVERTS. The pool never pins at beta (composition only approaches
 *         100% stable asymptotically). The $2M point sits exactly AT the E-CLP 5.0x max-invariant-ratio cap on
 *         tilt9999 (500k -> 2.5M of near-constant value-per-invariant) — a vault-guard boundary, measured and
 *         logged per tilt rather than assumed.
 *
 *         T6: a stables-only Vault-`initialize` prices the pool AT beta (x = 0 is the band's quote-rich
 *         endpoint), quoting ST above fair. KEY STRUCTURAL FINDING: both re-tilted betas sit WITHIN the 1 bp
 *         fee of the peg (beta - 1 = 0.000474 bp / 0.52988 bp), so beta*(1 - fee) < 1 and the optimal
 *         sell-ST arb is ZERO-SIZE — one-sided genesis costs the seeder NOTHING at the production fee, on any
 *         seed size (the fee shields the entire band by construction; this replaces the pre-registered
 *         expectation of an arb landing the pool at 90/10). The underlying curve convexity is surfaced with an
 *         explicitly-labelled diagnostic at the pool-minimum 1e12 fee: tilt9010 then loses a scale-invariant
 *         0.0254 bp of seed (arber sells ST to the p*(1-fee)=1 edge, composition lands at 90.19% stable, i.e.
 *         near the 90/10 balance point), while tilt9999's 0.000474 bp band headroom is below even the minimum
 *         admissible fee — its one-sided genesis is arb-free at ANY fee. Conservation (seeder loss == arber
 *         profit, fees retained in reserves) is asserted to rounding wei on every case.
 *
 *         DEVIATION NOTE (mechanics, not economics): the T5 round trip removes the whale's BPT (2/3 of total
 *         supply) in four tranches because the E-CLP `getMinimumInvariantRatio` of 0.6 blocks a one-shot
 *         single-token removal of that share; the tranche fees compound to the same single-sided exit cost.
 */
contract Test_WhaleAddAndGenesis_ECLPExitLiquidity is ECLPExitLiquidityBase {
    using FixedPoint for uint256;

    uint256 internal constant WHALE_POOL_TVL = 500_000e18;
    uint256 internal constant WHALE_ADD = 1_000_000e18;
    /// GyroECLPPool's minimum admissible swap fee (1e12 = 0.01 bp) — the T6 fee-shield diagnostic fee.
    uint256 internal constant MIN_POOL_FEE = 1e12;
    /// Offline invariant-math ladder predictions (predict_scenarios.py), bp*1e4 per size, per tilt.
    uint256 internal constant GENESIS_MINFEE_LOSS_PREDICTION_E4 = 254; // 0.0254 bp, tilt9010, any seed size

    /// T5 measurement bundle for one tilt (kept in memory to stay inside via_ir stack limits).
    struct WhaleRes {
        uint256 spotBefore;
        uint256 spotAfter;
        uint256 shareBefore;
        uint256 shareAfter;
        uint256 betaGap;
        int256 lossWei;
        int256 slipE4;
        uint256 bptOut;
        int256 roundTripE4;
    }

    /// T6 measurement bundle for one (tilt, seed, fee) case.
    struct GenesisRes {
        uint256 spotInit;
        uint256 arbProfit;
        uint256 stSold;
        uint256 feesRetained;
        int256 lossWei;
        int256 lossBpE4;
        int256 residual;
        uint256 shareAfter;
    }

    /*//////////////////////////////////////////////////////////////////////////
                              FRESH-POOL MACHINERY
    //////////////////////////////////////////////////////////////////////////*/

    /// Deploy + initialize a fresh salt-distinct pool of tilt `t` with exact seed amounts, and select it.
    function _freshPool(uint256 t, uint256 saltNum, uint256 x0, uint256 y0) internal {
        address p = _createPool(
            t == 0 ? _eclpParamsA() : _eclpParamsD(), t == 0 ? _derivedParamsA() : _derivedParamsD(), false, bytes32(saltNum)
        );
        vm.prank(lp);
        IERC20(p).approve(address(router), type(uint256).max);
        router.initialize(p, address(this), _tokens(), _two(x0, y0));
        pool = p;
        tilt = t;
    }

    /// Balance-point seed for an EXACT `totalValue` fair TVL: y0 = V*Y0/(Y0 + X0) (peg ratio), x0 the remainder.
    function _balancedSeed(uint256 t, uint256 totalValue) internal pure returns (uint256 x0, uint256 y0) {
        y0 = totalValue * Y0 / (Y0 + _x0Of(t));
        x0 = totalValue - y0;
    }

    /*//////////////////////////////////////////////////////////////////////////
                              T5 — WHALE ADD (2x TVL)
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice $1M single-sided stablecoin add (2x pool TVL) into a fresh $500k balance-point pool, then the
     *         full single-sided round trip back to stables — head-to-head. LP slippage = (deposit - BPT value
     *         as a pro-rata claim on post-add reserves at FAIR prices) / deposit. Offline predictions
     *         (predict_scenarios.py): 0.0392 bp on tilt9010, 0.0000333 bp on tilt9999; the pool ends BELOW
     *         beta on both tilts (never pinned).
     */
    function test_T5_WhaleAdd_1MSingleSidedOn500kPool_HeadToHead() public {
        WhaleRes memory a = _runWhaleAdd(0);
        WhaleRes memory d = _runWhaleAdd(1);
        _logPairedU("T5_WHALE_spot_before", "", a.spotBefore, d.spotBefore);
        _logPairedU("T5_WHALE_spot_after", "", a.spotAfter, d.spotAfter);
        _logPairedU("T5_WHALE_stable_share_before_e18", "", a.shareBefore, d.shareBefore);
        _logPairedU("T5_WHALE_stable_share_after_e18", "", a.shareAfter, d.shareAfter);
        _logPairedU("T5_WHALE_beta_minus_spot_after", "", a.betaGap, d.betaGap);
        _logPaired("T5_WHALE_slippage_bp_e4", "add=1M|pool=500k", a.slipE4, d.slipE4);
        _logPaired("T5_WHALE_slippage_wei", "add=1M|pool=500k", a.lossWei, d.lossWei);
        _logPaired("T5_WHALE_roundtrip_bp_e4", "add=1M|pool=500k", a.roundTripE4, d.roundTripE4);
        _logVerdict(
            "Q_whale_add_2x_tvl",
            "meaningful_slippage=false_both_tilts",
            string.concat("slippage_bp_e4_tilt9999=", _i(a.slipE4), "|tilt9010=", _i(d.slipE4), "|band_caps_impact_at_beta")
        );
    }

    /// Whale-add + round-trip measurement body for one tilt (fresh $500k pool, snapshot-isolated).
    function _runWhaleAdd(uint256 t) internal returns (WhaleRes memory res) {
        (uint256 snap, uint256 snapTs) = _snapState();
        (uint256 x0, uint256 y0) = _balancedSeed(t, WHALE_POOL_TVL);
        _freshPool(t, 100 + t, x0, y0);
        assertEq(_poolTvlAtFair(), WHALE_POOL_TVL, "the whale pool must initialize at exactly $500k of fair TVL");
        res.spotBefore = _spotPrice();
        res.shareBefore = _stableShare();
        assertApproxEqAbs(res.spotBefore, 1e18, 1e9, "the $500k whale pool must initialize on the peg");
        assertApproxEqAbs(res.shareBefore, _pegStableShareWad(t), 1e12, "the $500k whale pool must initialize at the tilt's balance-point composition");

        (, res.bptOut) = router.addLiquidityUnbalanced(pool, lp, _tokens(), _two(0, WHALE_ADD), 0);
        res.lossWei = int256(WHALE_ADD) - int256(_bptFairValue(res.bptOut));
        res.slipE4 = res.lossWei * 1e8 / int256(WHALE_ADD);
        res.spotAfter = _spotPrice();
        res.shareAfter = _stableShare();
        res.betaGap = _betaOf(t) - res.spotAfter;

        assertGe(res.lossWei, 0, "the unbalanced add must not mint BPT above fair value (rounding is pool-favoring)");
        assertLt(res.spotAfter, _betaOf(t), "the pool must NOT end pinned at beta: a quote add approaches the edge only asymptotically");
        assertGt(res.betaGap, 1e9, "the post-add spot must keep a measurable gap below beta (predicted 1.6e-8/1.8e-5 of price)");
        if (t == 0) {
            assertLe(res.slipE4, 2, "tilt9999 whale slippage must be ~0.0000333 bp (band headroom is 4.7e-8 of price)");
            assertLe(res.lossWei, 1e16, "tilt9999 whale loss must stay near the predicted $0.0033 on $1M");
            assertApproxEqAbs(res.shareAfter, 999_966_600_000_000_000, 1e13, "tilt9999 composition must land at ~99.9967% stable after the add");
        } else {
            // Offline invariant-math prediction 392 bp*1e4 (0.0392 bp); band = prediction +-30% catches any
            // regime error while never hiding a real cost (the assertion ceiling is ~0.05 bp).
            assertGe(res.slipE4, 274, "tilt9010 whale slippage must be at least 0.7x the 0.0392 bp invariant-math prediction");
            assertLe(res.slipE4, 510, "tilt9010 whale slippage must be at most 1.3x the 0.0392 bp invariant-math prediction");
            assertApproxEqAbs(res.shareAfter, 966_666_000_000_000_000, 5e13, "tilt9010 composition must land at ~96.667% stable after the add");
        }

        // Round trip: remove the same BPT single-sided back to stables in four tranches (header deviation:
        // the E-CLP 0.6 min-invariant-ratio blocks a one-shot removal of a 2/3-supply position).
        uint256 qBack;
        for (uint256 c = 0; c < 4; ++c) {
            uint256 chunk = c == 3 ? IERC20(pool).balanceOf(lp) : res.bptOut / 4;
            qBack += router.removeLiquiditySingleTokenExactIn(pool, lp, chunk, _tokens(), 1, 0);
        }
        res.roundTripE4 = (int256(WHALE_ADD) - int256(qBack)) * 1e8 / int256(WHALE_ADD);
        // Ge, not Gt: on tilt9999 a stable add into a 99.99%-stable pool is proportional to within integer
        // rounding, so the round trip can legitimately cost exactly 0 wei; negative would mean free extraction.
        assertGe(res.roundTripE4, 0, "the whale round trip must never be negative (free extraction)");
        assertLe(res.roundTripE4, 2 * res.slipE4 + 2_000, "the whale round trip must not exceed twice the one-way slippage plus 0.2 bp of remove-fee slack");
        assertLt(res.roundTripE4, 10_000, "VERDICT input: a 2x-TVL whale round trip must cost under 1 bp");
        _restoreState(snap, snapTs);
        _logMetric(
            "T5_WHALE",
            string.concat(
                "pool=", _tiltLabel(t), "|add=1000000e18|bpt_out=", _u(res.bptOut), "|slippage_bp_e4=", _i(res.slipE4), "|slippage_wei=",
                _i(res.lossWei), "|spot_after=", _u(res.spotAfter), "|beta_gap=", _u(res.betaGap), "|share_after_e18=", _u(res.shareAfter),
                "|roundtrip_bp_e4=", _i(res.roundTripE4)
            )
        );
    }

    /**
     * @notice Single-sided add size ladder {100k, 250k, 500k, 1M, 2M} on the same fresh $500k pool state
     *         (snapshot-isolated per size). The measured profile INVERTS the naive convexity expectation:
     *         per-dollar slippage FALLS with size (predictions 870/725/566/392/242 bp*1e4 on tilt9010) because
     *         the band caps the implicit-buy premium at beta - 1 while a bigger add owns a bigger pro-rata
     *         share of its own fee. The $2M point additionally probes the 5.0x max-invariant-ratio vault cap.
     */
    function test_T5_WhaleAdd_SizeLadder_PerDollarSlippageFallsWithSize() public {
        (int256[5] memory slipA, bool[5] memory okA) = _runLadder(0);
        (int256[5] memory slipD, bool[5] memory okD) = _runLadder(1);
        uint256[5] memory sizes = [uint256(100_000), 250_000, 500_000, 1_000_000, 2_000_000];
        for (uint256 k = 0; k < 5; ++k) {
            _logPaired(
                "T5_LADDER_slippage_bp_e4",
                string.concat("add_usd=", _u(sizes[k]), "|ok9999=", okA[k] ? "1" : "0", "|ok9010=", okD[k] ? "1" : "0"),
                slipA[k],
                slipD[k]
            );
        }
        // tilt9010 predictions (offline invariant math): 870/725/566/392/242 bp*1e4, +-30%.
        uint256[5] memory predD = [uint256(870), 725, 566, 392, 242];
        for (uint256 k = 0; k < 5; ++k) {
            assertTrue(okD[k], "every ladder size must clear the 5x invariant-ratio cap on tilt9010 (2M lands at 4.9999916x)");
            assertGe(slipD[k], int256(predD[k] * 7 / 10), "each tilt9010 ladder slippage must be at least 0.7x its invariant-math prediction");
            assertLe(slipD[k], int256(predD[k] * 13 / 10), "each tilt9010 ladder slippage must be at most 1.3x its invariant-math prediction");
            if (k > 0) assertLt(slipD[k], slipD[k - 1], "tilt9010 per-dollar slippage must fall strictly with size (band-capped impact + fee recoup)");
            if (okA[k]) assertLe(slipA[k], 2, "every tilt9999 ladder slippage must be ~0 at bp*1e4 resolution (< 0.0002 bp)");
        }
    }

    /// Ladder body for one tilt: one fresh $500k pool, each size measured from an inner snapshot.
    function _runLadder(uint256 t) internal returns (int256[5] memory slipE4, bool[5] memory ok) {
        (uint256 snap, uint256 snapTs) = _snapState();
        (uint256 x0, uint256 y0) = _balancedSeed(t, WHALE_POOL_TVL);
        _freshPool(t, 110 + t, x0, y0);
        uint256[5] memory sizes = [uint256(100_000e18), 250_000e18, 500_000e18, 1_000_000e18, 2_000_000e18];
        for (uint256 k = 0; k < 5; ++k) {
            (uint256 inner, uint256 innerTs) = _snapState();
            try router.addLiquidityUnbalanced(pool, lp, _tokens(), _two(0, sizes[k]), 0) returns (uint256[] memory, uint256 bptOut) {
                ok[k] = true;
                slipE4[k] = (int256(sizes[k]) - int256(_bptFairValue(bptOut))) * 1e8 / int256(sizes[k]);
            } catch {
                ok[k] = false;
                slipE4[k] = -1; // sentinel: revert (5x invariant-ratio cap), logged in the paired metric ctx
            }
            _restoreState(inner, innerTs);
            _logMetric(
                "T5_LADDER",
                string.concat(
                    "pool=", _tiltLabel(t), "|add_wei=", _u(sizes[k]), "|ok=", ok[k] ? "1" : "0", "|slippage_bp_e4=", _i(slipE4[k])
                )
            );
        }
        _restoreState(snap, snapTs);
    }

    /*//////////////////////////////////////////////////////////////////////////
                          T6 — ONE-SIDED GENESIS LOSS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Stables-only genesis (Vault `initialize` with [0, seed]) across seeds {10k, 100k, 1M},
     *         head-to-head, at the production 1 bp fee AND at the 1e12 pool-minimum fee (diagnostic), plus the
     *         balanced-seeding counterfactual. Init prices the pool AT beta; because beta*(1 - fee) < 1 on
     *         both tilts the optimal arb at the production fee is ZERO — the seeder loses nothing, at any
     *         scale (asserted exactly, not with tolerances). The min-fee diagnostic surfaces the shielded
     *         curve convexity: tilt9010 loses a scale-invariant 0.0254 bp (composition lands near 90/10);
     *         tilt9999 is arb-free even at the minimum admissible fee. Conservation seeder-loss == arber-profit
     *         is asserted to 2 wei on every case; one-sided-vs-balanced cost is logged per seed.
     */
    function test_T6_OneSidedGenesis_StablesOnlyInit_FeeShieldsTheBand_HeadToHead() public {
        // The structural reason there is no arb: beta net of the production fee sits BELOW fair on both tilts.
        for (uint256 t = 0; t < 2; ++t) {
            assertLt(_betaOf(t).mulDown(1e18 - SWAP_FEE), 1e18, "beta*(1-fee) must sit below fair: the fee shields one-sided genesis by construction");
        }

        uint256[3] memory seeds = [uint256(10_000e18), 100_000e18, 1_000_000e18];
        string[3] memory seedLabels = ["10k", "100k", "1M"];
        int256[3] memory minFeeLossD;
        for (uint256 s = 0; s < 3; ++s) {
            // Production 1 bp fee: the answer-grade case.
            GenesisRes memory a = _runGenesis(0, 120 + s, seeds[s], SWAP_FEE);
            GenesisRes memory d = _runGenesis(1, 140 + s, seeds[s], SWAP_FEE);
            assertEq(a.arbProfit, 0, "tilt9999 one-sided genesis must offer zero arb at the production fee");
            assertEq(d.arbProfit, 0, "tilt9010 one-sided genesis must offer zero arb at the production fee");
            assertEq(a.lossWei, 0, "the tilt9999 seeder must lose exactly nothing at the production fee");
            assertEq(d.lossWei, 0, "the tilt9010 seeder must lose exactly nothing at the production fee");
            _logPairedU("T6_GENESIS_spot_init", string.concat("seed=", seedLabels[s]), a.spotInit, d.spotInit);
            _logPaired("T6_GENESIS_loss_bp_e4", string.concat("seed=", seedLabels[s], "|fee_bp_e4=10000"), a.lossBpE4, d.lossBpE4);
            _logPaired("T6_GENESIS_loss_wei", string.concat("seed=", seedLabels[s], "|fee_bp_e4=10000"), a.lossWei, d.lossWei);
            _logPairedU("T6_GENESIS_arb_profit", string.concat("seed=", seedLabels[s], "|fee_bp_e4=10000"), a.arbProfit, d.arbProfit);

            // Pool-minimum-fee diagnostic: the curve convexity the production fee shields.
            GenesisRes memory am = _runGenesis(0, 160 + s, seeds[s], MIN_POOL_FEE);
            GenesisRes memory dm = _runGenesis(1, 180 + s, seeds[s], MIN_POOL_FEE);
            minFeeLossD[s] = dm.lossBpE4;
            assertEq(am.arbProfit, 0, "tilt9999 must be arb-free even at the minimum admissible fee (band headroom 4.7e-8 < 1e-6 fee)");
            assertGt(dm.arbProfit, 0, "the min-fee diagnostic must surface tilt9010's shielded convexity as a real arb");
            assertApproxEqAbs(
                dm.lossBpE4,
                int256(GENESIS_MINFEE_LOSS_PREDICTION_E4),
                40,
                "the tilt9010 min-fee genesis loss must match the 0.0254 bp invariant-math prediction"
            );
            assertGe(dm.shareAfter, 899_000_000_000_000_000, "the min-fee arb must land tilt9010 near the 90/10 balance point (>= 89.9% stable)");
            assertLe(dm.shareAfter, 905_000_000_000_000_000, "the min-fee arb must land tilt9010 near the 90/10 balance point (<= 90.5% stable)");
            _logPaired("T6_GENESIS_minfee_loss_bp_e4", string.concat("seed=", seedLabels[s], "|fee_bp_e4=100"), am.lossBpE4, dm.lossBpE4);
            _logPairedU("T6_GENESIS_minfee_share_after_e18", string.concat("seed=", seedLabels[s]), am.shareAfter, dm.shareAfter);
            _logPairedU("T6_GENESIS_minfee_fees_retained_wei", string.concat("seed=", seedLabels[s]), am.feesRetained, dm.feesRetained);
            _logPaired("T6_GENESIS_conservation_residual_wei", string.concat("seed=", seedLabels[s]), am.residual, dm.residual);

            // Counterfactual: balanced seeding at the same fair value offers no arb at either fee (asserted
            // zero-loss inside), so the "one-sided cost vs balanced seeding" equals the one-sided loss itself.
            int256 cfA = _runBalancedCounterfactual(0, 200 + s, seeds[s], SWAP_FEE);
            int256 cfD = _runBalancedCounterfactual(1, 220 + s, seeds[s], SWAP_FEE);
            int256 cfAm = _runBalancedCounterfactual(0, 240 + s, seeds[s], MIN_POOL_FEE);
            int256 cfDm = _runBalancedCounterfactual(1, 260 + s, seeds[s], MIN_POOL_FEE);
            _logPaired(
                "T6_GENESIS_vs_balanced_bp_e4", string.concat("seed=", seedLabels[s], "|fee_bp_e4=10000"), a.lossBpE4 - cfA, d.lossBpE4 - cfD
            );
            _logPaired(
                "T6_GENESIS_minfee_vs_balanced_bp_e4",
                string.concat("seed=", seedLabels[s], "|fee_bp_e4=100"),
                am.lossBpE4 - cfAm,
                dm.lossBpE4 - cfDm
            );
        }

        // Scale invariance: AMM math predicts the loss in bps is seed-independent; measured spread must be
        // within the arb-search resolution (DUST_PROFIT on the smallest seed is 0.2 bp*1e4).
        assertApproxEqAbs(minFeeLossD[0], minFeeLossD[1], 5, "the min-fee genesis loss in bps must be scale-invariant (10k vs 100k)");
        assertApproxEqAbs(minFeeLossD[1], minFeeLossD[2], 5, "the min-fee genesis loss in bps must be scale-invariant (100k vs 1M)");
        _logVerdict(
            "Q_one_sided_genesis",
            "arb=none_at_production_fee_both_tilts",
            string.concat(
                "beta_minus_1_bp_e4_tilt9999=5|tilt9010=5299|fee_bp_e4=10000|minfee_diag_loss_bp_e4_tilt9010=",
                _i(minFeeLossD[1]),
                "|scale_invariant=true"
            )
        );
    }

    /// Genesis measurement body for one (tilt, seed, fee): stables-only init, optimal arb, conservation check.
    function _runGenesis(uint256 t, uint256 saltNum, uint256 seed, uint256 feeWad) internal returns (GenesisRes memory res) {
        (uint256 snap, uint256 snapTs) = _snapState();
        _freshPool(t, saltNum, 0, seed);
        if (feeWad != SWAP_FEE) vault.manualUnsafeSetStaticSwapFeePercentage(pool, feeWad);
        res.spotInit = _spotPrice();
        assertApproxEqAbs(res.spotInit, _betaOf(t), 1e10, "a stables-only init must price the pool AT beta, the stable-rich band edge");
        assertGt(res.spotInit, 1e18, "the one-sided genesis pool must quote ST above the 1.0 fair price");

        (res.arbProfit, res.stSold) = _genesisArb();
        res.feesRetained = res.stSold.mulUp(feeWad); // ST-side swap fee, valued at the 1.0 fair rate
        uint256 poolAfter = _poolTvlAtFair();
        res.lossWei = int256(seed) - int256(poolAfter);
        res.lossBpE4 = res.lossWei * 1e8 / int256(seed);
        res.residual = res.lossWei - int256(res.arbProfit);
        res.shareAfter = _stableShare();
        // Conservation: every token is in the pool or the arber's wallet, and fees stay in pool reserves, so
        // at fair rates seeder loss == arber profit identically.
        assertLe(res.residual >= 0 ? res.residual : -res.residual, 2, "the seeder loss must equal the arber profit to within rounding wei");
        _restoreState(snap, snapTs);
        _logMetric(
            "T6_GENESIS",
            string.concat(
                "pool=", _tiltLabel(t), "|seed_wei=", _u(seed), "|fee_bp_e4=", _u(feeWad / 1e10), "|spot_init=", _u(res.spotInit),
                "|arb_profit=", _u(res.arbProfit), "|st_sold=", _u(res.stSold), "|fees_retained=", _u(res.feesRetained), "|seeder_loss_wei=",
                _i(res.lossWei), "|seeder_loss_bp_e4=", _i(res.lossBpE4), "|residual=", _i(res.residual), "|share_after_e18=", _u(res.shareAfter)
            )
        );
    }

    /// Optimal-arb rounds against a genesis pool, tracking total ST sold for the fee-retention ledger.
    function _genesisArb() internal returns (uint256 profit, uint256 stSold) {
        for (uint256 round = 0; round < ARB_MAX_ROUNDS; ++round) {
            (uint256 pr, uint256 amt, bool sellSt) = _optimalArb();
            if (pr <= DUST_PROFIT) break;
            assertTrue(sellSt, "the only edge against a stables-only pool must be selling ST into it");
            int256 stBefore = int256(st.balanceOf(arber));
            int256 qBefore = int256(quoteToken.balanceOf(arber));
            router.swapExactIn(pool, arber, IERC20(address(st)), IERC20(address(quoteToken)), amt, 0);
            int256 realized = (int256(st.balanceOf(arber)) - stBefore) * int256(_fairStRate()) / 1e18
                + (int256(quoteToken.balanceOf(arber)) - qBefore) * int256(_fairQRate()) / 1e18;
            assertEq(realized, int256(pr), "the realized genesis-arb PnL at fair must equal the quoted optimum (coherent measurement)");
            profit += pr;
            stSold += amt;
        }
    }

    /// Balanced-seeding counterfactual: same fair value seeded at the peg ratio offers no arb at any fee.
    function _runBalancedCounterfactual(uint256 t, uint256 saltNum, uint256 seed, uint256 feeWad) internal returns (int256 lossBpE4) {
        (uint256 snap, uint256 snapTs) = _snapState();
        (uint256 x0, uint256 y0) = _balancedSeed(t, seed);
        _freshPool(t, saltNum, x0, y0);
        if (feeWad != SWAP_FEE) vault.manualUnsafeSetStaticSwapFeePercentage(pool, feeWad);
        (uint256 profit,) = _genesisArb();
        assertEq(profit, 0, "balanced seeding at the peg must offer no arb even at the minimum admissible fee");
        assertEq(_poolTvlAtFair(), seed, "the balanced-seeded pool must retain its full seed value (no arb possible)");
        lossBpE4 = (int256(seed) - int256(_poolTvlAtFair())) * 1e8 / int256(seed);
        _restoreState(snap, snapTs);
    }
}

/**
 * @title Test_ExtremeCadence_ECLPExitLiquidity
 * @notice T7 — user-specified extreme rate-cadence asymmetry, head-to-head: the QUOTE stable's oracle updates
 *         once per SECOND while the ST share's oracle updates once per MONTH (a +65.75 bp stale-mark snap at
 *         each boundary under the file's simple-rate step convention). Three 30-day cycles, an optimal arber
 *         at 6-hour checkpoints, no exit flow (the cadence effect is isolated), every PnL at external fair.
 *
 * @dev PER-SECOND EQUIVALENCE (why stepping the quote mark at checkpoints is exact, not a shortcut): the
 *      vault reads a rate provider ONLY inside pool operations, and every pool operation in this simulation
 *      occurs at a checkpoint. The quote oracle is stepped at every checkpoint instant, so at every executed
 *      trade the quote oracle equals the true accrued quote rate EXACTLY (fair == mark at marks, asserted
 *      each checkpoint) — indistinguishable, trade for trade, from a provider recomputed every second.
 *      Between checkpoints nothing reads the rate, so no information is lost. The ST mark, by contrast, is
 *      genuinely stale: fair ST drifts up to +65.75 bp above its mark within each month.
 *
 * @dev CHECKPOINT INTERVAL (6h): the arbable ST edge grows 65.75 bp / 120 checkpoints ~= 0.55 bp/day, i.e.
 *      ~0.137 bp per checkpoint — an order below the 1 bp fee. Discretization can defer a marginally
 *      profitable strip by at most one checkpoint, changing extraction by <= inventory x 0.137 bp; the paired
 *      deltas measured here are orders larger, so the grid does not shape the findings.
 *
 * @dev EXPECTED MECHANICS, derived from the band geometry (measured below, asserted structurally):
 *      the quote leg tracks fair, so the fair scaled ratio q* rises from 1 toward 1.006575 within each cycle
 *      while pool spot is capped at beta (tilt9999: 1 + 4.74e-8; tilt9010: 1 + 5.2988e-5). The arber buys the
 *      ST leg as soon as q*(1 - fee) clears spot (~11-17h in), the pool pins at beta ST-empty, and — because
 *      beta*(1 - fee) < 1 on both tilts — the post-snap reverse arb is fee-blocked: inventory never refills,
 *      cycles 2-3 extract nothing. The arb MARGIN extracted is therefore one-time and thin — but the strip's
 *      real LP cost is the FORCED-ROTATION CARRY DRAG it causes: the pool is rotated out of the 8%-yielding
 *      ST leg into the 3%-yielding quote within hours of each mark going stale, ceding the 5%/yr yield
 *      spread on the whole ST allocation (~= inventory x 5% x horizon; measured as the conservation
 *      residual and asserted against that identity). The other casualty is EXECUTION QUALITY: a mid-cycle
 *      exiter sells ST against the stale mark and is underpaid by ~(drift-to-date + fee - (beta - 1)),
 *      ~33 bp at day 15, ~65 bp at month-end.
 *      Implied minimum safe ST cadence at a 1 bp fee: per-period ST-only drift 2.19 bp/day <= 1 bp requires
 *      marks at least every ~0.46 days; conversely the month-long gap here is ~66x past breakeven.
 */
contract Test_ExtremeCadence_ECLPExitLiquidity is ECLPExitLiquidityBase {
    using FixedPoint for uint256;

    /// Monthly ST oracle step under the file's simple-rate convention: 1e18 + 8e16 * 30 / 365.
    uint256 internal constant ST_STEP_30D = 1_006_575_342_465_753_424;
    uint256 internal constant CHECKPOINT = 6 hours;
    uint256 internal constant CYCLE = 30 days;
    uint256 internal constant CYCLES = 3;
    uint256 internal constant CHECKPOINTS_PER_CYCLE = 120; // CYCLE / CHECKPOINT
    /// Mid-cycle exiter probe size ($10k of ST at fair) and its checkpoint (day 15 of cycle 0).
    uint256 internal constant EXITER_PROBE = 10_000e18;
    uint256 internal constant PROBE_CHECKPOINT = 60;

    /**
     * @notice Expected day-15 exiter haircut in bp*1e4, from the pinned-pool execution identity
     *         haircut = 1 - beta*(1 - fee)/(1 + drift(15d)) with drift(15d) = 32.877 bp:
     *         tilt9999 ~= 337_570 (33.76 bp), tilt9010 ~= 332_290 (33.23 bp). Asserted +-10%.
     */
    uint256 internal constant PROBE_HAIRCUT_PREDICTION_9999_E4 = 337_570;
    uint256 internal constant PROBE_HAIRCUT_PREDICTION_9010_E4 = 332_290;

    /// T7 measurement bundle for one tilt (memory struct keeps via_ir stack shallow).
    struct CadenceRes {
        uint256 extraction; // total arb extraction at fair over the 3 cycles
        uint256 cycle1Extraction;
        uint256 laterExtraction; // cycles 2 + 3 (refill-blocked expectation: ~0)
        uint256 timeToStrip; // seconds from sim start until the ST leg first drops below 1% of initial
        uint256 pinnedCheckpoints; // post-strip checkpoints with no extractable arb
        uint256 snapReverseArb; // post-snap reverse-arb profit over all cycles (fee-blocked expectation: 0)
        int256 exiterHaircutE4; // day-15 probe: fair-vs-execution underpayment on a $10k ST exit, bp*1e4
        int256 lpNetWei; // pool end fair value minus the hold-the-seed benchmark
        int256 residualWei; // conservation: (benchmark - poolEnd) - extraction == the forced-rotation carry drag
        uint256 strippedRaw; // raw ST the arber permanently removed (stRaw0 - stRawEnd), the carry-drag notional
        uint256 stInventoryFair0; // initial ST leg at fair (the extraction cap's base)
        uint256 tvl0; // initial fair TVL (annualization base)
    }

    function test_T7_ExtremeCadence_PerSecondQuote_MonthlyStMarks_HeadToHead() public {
        CadenceRes memory a = _runCadence(0);
        CadenceRes memory d = _runCadence(1);

        // Head-to-head: the 90/10 pool's ~1000x ST inventory is the arb surface.
        assertGe(d.extraction, a.extraction, "tilt9010 must leak at least as much as tilt9999 (1000x the strippable inventory)");

        // The strip is fast (drift crosses the fee within ~11-17h) and one-time (refill is fee-blocked).
        for (uint256 t = 0; t < 2; ++t) {
            CadenceRes memory r = t == 0 ? a : d;
            assertGe(r.timeToStrip, CHECKPOINT, "the strip cannot precede the first checkpoint");
            assertLe(r.timeToStrip, 1 days, "the ST leg must be stripped within a day of drift crossing the fee");
            assertLe(r.snapReverseArb, CYCLES * DUST_PROFIT, "beta*(1-fee) < 1 must fee-block the post-snap refill arb");
            assertLe(r.laterExtraction, r.extraction / 10 + DUST_PROFIT, "cycles 2-3 must extract ~nothing: the one-time strip is the whole leak");
            assertLe(
                r.extraction,
                r.stInventoryFair0.mulDown(CYCLES * (ST_STEP_30D - 1e18)) * 2,
                "extraction must be capped by inventory x cumulative drift (doubled slack for impact interplay)"
            );
            assertGe(
                r.pinnedCheckpoints,
                (CYCLES * CHECKPOINTS_PER_CYCLE * 8) / 10,
                "the pool must sit pinned and inert for >= 80% of the horizon"
            );
            /**
             * Conservation with the CARRY-DRAG term — the dominant LP cost this scenario surfaces. The strip
             * itself extracts only the thin over-fee entry margin, but it force-rotates the pool out of the
             * 8%-yielding ST leg into the 3%-yielding quote a month early, every month: the LP cedes the
             * yield spread on the stripped notional for the rest of the horizon. First-order identity:
             *   benchmark - poolEnd = extraction + carryDrag,
             *   carryDrag ~= strippedNotional x (8% - 3%) x (horizon - timeToStrip) / 365d.
             * Asserted within +-50% (multi-checkpoint strip timing, simple-vs-compound accrual, later-cycle
             * dribbles); the measured value is reported as a first-class metric below.
             */
            uint256 expectedCarry =
                r.strippedRaw.mulDown(uint256(5e16)) * (CYCLES * CYCLE - r.timeToStrip) / 365 days;
            uint256 residualAbs = r.residualWei < 0 ? uint256(-r.residualWei) : uint256(r.residualWei);
            assertGe(residualAbs + 1e15, expectedCarry / 2, "the ledger residual must be explained by the forced-rotation carry drag (lower band)");
            assertLe(residualAbs, expectedCarry * 3 / 2 + 1e15, "the ledger residual must be explained by the forced-rotation carry drag (upper band)");
            assertLe(r.lpNetWei, int256(0), "the LP can never beat the hold benchmark under pure adverse cadence (no flow, no fee income)");
        }

        // The decisive finding: mid-cycle exit execution is degraded by the stale mark on BOTH tilts.
        assertApproxEqAbs(
            a.exiterHaircutE4,
            int256(PROBE_HAIRCUT_PREDICTION_9999_E4),
            PROBE_HAIRCUT_PREDICTION_9999_E4 / 10,
            "the tilt9999 day-15 exiter haircut must match the pinned-pool execution identity within 10%"
        );
        assertApproxEqAbs(
            d.exiterHaircutE4,
            int256(PROBE_HAIRCUT_PREDICTION_9010_E4),
            PROBE_HAIRCUT_PREDICTION_9010_E4 / 10,
            "the tilt9010 day-15 exiter haircut must match the pinned-pool execution identity within 10%"
        );

        _logPairedU("T7_EXTRACTION_total_wei", "", a.extraction, d.extraction);
        _logPairedU("T7_EXTRACTION_bp_yr_e4", "", _bpE4(a.extraction * 365 / 90, a.tvl0), _bpE4(d.extraction * 365 / 90, d.tvl0));
        _logPairedU("T7_EXTRACTION_cycle1_wei", "", a.cycle1Extraction, d.cycle1Extraction);
        _logPairedU("T7_EXTRACTION_cycles23_wei", "", a.laterExtraction, d.laterExtraction);
        _logPairedU("T7_TIME_TO_STRIP_secs", "", a.timeToStrip, d.timeToStrip);
        _logPairedU("T7_PINNED_checkpoints_of_360", "", a.pinnedCheckpoints, d.pinnedCheckpoints);
        _logPairedU("T7_SNAP_REVERSE_ARB_wei", "", a.snapReverseArb, d.snapReverseArb);
        _logPaired("T7_EXITER_HAIRCUT_day15_bp_e4", "probe=10000e18", a.exiterHaircutE4, d.exiterHaircutE4);
        _logPaired("T7_LP_NET_VS_HOLD_wei", "", a.lpNetWei, d.lpNetWei);
        _logPaired("T7_LP_NET_VS_HOLD_bp_e4", "", a.lpNetWei * 1e8 / int256(a.tvl0), d.lpNetWei * 1e8 / int256(d.tvl0));
        _logPaired("T7_CARRY_DRAG_wei", "residual==carry", a.residualWei, d.residualWei);
        _logPairedU("T7_CARRY_DRAG_bp_yr_e4", "", _bpE4(uint256(a.residualWei) * 365 / 90, a.tvl0), _bpE4(uint256(d.residualWei) * 365 / 90, d.tvl0));
        _logPairedU("T7_STRIPPED_ST_raw", "", a.strippedRaw, d.strippedRaw);
        _logVerdict(
            "extreme_cadence_monthly_st_marks",
            "ARB_MARGIN_ONE_TIME__CARRY_DRAG_IS_THE_LP_COST__EXECUTION_QUALITY_DESTROYED",
            string.concat(
                "haircut_day15_bp_e4_9999=", _i(a.exiterHaircutE4), "|haircut_day15_bp_e4_9010=", _i(d.exiterHaircutE4),
                "|lp_net_bp_e4_9999=", _i(a.lpNetWei * 1e8 / int256(a.tvl0)), "|lp_net_bp_e4_9010=", _i(d.lpNetWei * 1e8 / int256(d.tvl0)),
                "|min_safe_st_cadence_days_at_1bp_fee=0.46"
            )
        );
    }

    /// Run the full 3-cycle cadence simulation on tilt `t` inside a state snapshot; returns the measurements.
    function _runCadence(uint256 t) internal returns (CadenceRes memory r) {
        (uint256 snap, uint256 ts0) = _snapState();
        _usePool(t);
        _setStCadence(ST_STEP_30D, CYCLE);
        _setQuoteCadence(Q_STEP_6H, CHECKPOINT);

        uint256 simStart = nowTs;
        (uint256 stRaw0,) = _rawBalances();
        r.stInventoryFair0 = stRaw0.mulDown(_fairStRate());
        r.tvl0 = _poolTvlAtFair();
        uint256 x0 = _x0Of(t);
        bool stripped;

        for (uint256 c = 0; c < CYCLES; ++c) {
            uint256 cycleStart = stMarkTs;
            uint256 cycleExtraction;
            for (uint256 k = 1; k <= CHECKPOINTS_PER_CYCLE; ++k) {
                _warpTo(cycleStart + k * CHECKPOINT);
                _stepQuoteOracle();
                assertEq(_fairQRate(), qMark, "the quote oracle must equal quote fair at every trade instant (per-second equivalence)");
                uint256 p = _arbToFeeEdge();
                cycleExtraction += p;
                if (!stripped) {
                    (uint256 sr,) = _rawBalances();
                    if (sr < stRaw0 / 100) {
                        stripped = true;
                        r.timeToStrip = nowTs - simStart;
                    }
                } else if (p <= DUST_PROFIT) {
                    ++r.pinnedCheckpoints;
                }
                if (c == 0 && k == PROBE_CHECKPOINT) r.exiterHaircutE4 = _exiterProbe();
            }
            // Monthly ST snap at the boundary: fair meets the new mark (gap resets to zero), then the
            // reverse-refill arb is attempted and folded into the same cycle's extraction.
            _stepStOracle();
            uint256 rev = _arbToFeeEdge();
            r.snapReverseArb += rev;
            cycleExtraction += rev;

            r.extraction += cycleExtraction;
            if (c == 0) r.cycle1Extraction = cycleExtraction;
            else r.laterExtraction += cycleExtraction;
        }

        uint256 lpEnd = _poolTvlAtFair();
        uint256 benchEnd = x0.mulDown(_fairStRate()) + Y0.mulDown(_fairQRate());
        (uint256 stRawEnd,) = _rawBalances();
        r.strippedRaw = stRaw0 - stRawEnd;
        r.lpNetWei = int256(lpEnd) - int256(benchEnd);
        r.residualWei = (int256(benchEnd) - int256(lpEnd)) - int256(r.extraction);
        _restoreState(snap, ts0);
    }

    /**
     * @notice Day-15 execution-quality probe: a $10k-fair ST exit against the stripped, stale-marked pool.
     *         Snapshot-isolated so the probe never perturbs the simulation it measures. The haircut is the
     *         exiter's fair-valued underpayment: (fair of ST sold - fair of quote received) / fair of ST sold.
     */
    function _exiterProbe() internal returns (int256 haircutE4) {
        (uint256 snap, uint256 ts) = _snapState();
        uint256 qOut = router.swapExactIn(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), EXITER_PROBE, 0);
        uint256 fairIn = EXITER_PROBE.mulDown(_fairStRate());
        uint256 fairOut = qOut.mulDown(_fairQRate());
        haircutE4 = (int256(fairIn) - int256(fairOut)) * 1e8 / int256(fairIn);
        _restoreState(snap, ts);
    }
}
