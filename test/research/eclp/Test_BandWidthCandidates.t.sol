// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { GyroECLPPool } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPool.sol";
import { FixedPoint } from "../../../lib/balancer-v3-monorepo/pkg/solidity-utils/contracts/math/FixedPoint.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ECLPExitLiquidityBase } from "./Test_ECLPExitLiquidityPoolEconomics.t.sol";

/**
 * @title Test_BandWidthCandidates_ECLPExitLiquidity
 * @notice T8: the band-width redesign battery. The production band (alpha = peg - 15 bp, lambda = 4000)
 *         concentrates so hard at the peg that a heavily drained pool offers arbers only a ~2 bp net
 *         restock margin — too thin to trust as THE exit-liquidity restoration mechanism (arbs are the
 *         only restorer in Day; marginal LPs are assumed away). These candidates trade at-peg depth for
 *         an arb signal that gets compelling early and reaches ~100+ bp when the pool is very one-sided:
 *
 *           A  (baseline) alpha = peg - 15 bp,  lambda = 4000  (the shipped 99.99 candidate)
 *           C1            alpha = 1/1.015,      lambda = 300   (~148 bp floor, fast ramp)
 *           C2            alpha = 1/1.01,       lambda = 300   (~100 bp floor, fast ramp)
 *           C3            alpha = 1/1.015,      lambda = 500   (~148 bp floor, deeper top)
 *
 *         All four share the 99.99% stable tilt (beta re-solved per band by the same 100-digit mpmath
 *         pipeline that reproduces candidates A/D and X0_9999 to the last digit), the 45-degree rotation,
 *         the 1 bp fee, and both legs WITH_RATE. Every number is measured on the real vault: drain to an
 *         anchor with a real EXACT_OUT exiter sell, read the spot, then run the optimal-arb machinery to
 *         the fee edge and account the arber's restock margin at fair. Rates sit at their marks
 *         throughout (no warps), so fair == oracle == 1e18 and the band discount is the entire signal —
 *         the drift subsidy of Idea 2 is deliberately excluded from these margins.
 *
 *         Regenerate: forge test --match-contract Test_BandWidthCandidates -vv | grep -E "METRIC|VERDICT"
 */
contract Test_BandWidthCandidates_ECLPExitLiquidity is ECLPExitLiquidityBase {
    using FixedPoint for uint256;

    // ST at the balance point (p = 1) for Y0 quote, per candidate (mpmath pipeline, from the rounded beta).
    uint256 internal constant X0_C1 = 1_000_100_010_000_524_809_194;
    uint256 internal constant X0_C2 = 1_000_100_010_001_395_082_958;
    uint256 internal constant X0_C3 = 1_000_100_010_000_673_267_521;
    uint256 internal constant X0_C4 = 1_000_100_010_001_551_384_104;

    address internal poolC1;
    address internal poolC2;
    address internal poolC3;
    address internal poolC4;

    /*//////////////////////////////////////////////////////////////////////////
                       CANDIDATE PARAMS (mpmath pipeline output)
    //////////////////////////////////////////////////////////////////////////*/

    /// C1: alpha = 1/1.015 (floor ~148 bp under peg), lambda = 300; beta solved for the 99.99% tilt.
    function _eclpParamsC1() internal pure returns (IGyroECLPPool.EclpParams memory) {
        return IGyroECLPPool.EclpParams({
            alpha: 985_221_674_876_847_291,
            beta: 1_000_000_607_199_568_608,
            c: 707_106_781_186_547_524,
            s: 707_106_781_186_547_524,
            lambda: 300_000_000_000_000_000_000
        });
    }

    function _derivedParamsC1() internal pure returns (IGyroECLPPool.DerivedEclpParams memory) {
        return IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({ x: -91_267_892_998_666_575_227_947_523_567_959_487_520, y: 40_867_734_309_402_922_018_736_502_219_875_192_745 }),
            tauBeta: IGyroECLPPool.Vector2({ x: 9_107_990_726_158_074_397_951_031_994_383_804, y: 99_999_999_585_222_523_744_202_835_739_725_890_028 }),
            u: 45_638_500_494_696_366_599_429_673_579_047_544_153,
            v: 70_433_866_947_312_722_801_614_633_734_070_095_692,
            w: 29_566_132_637_909_800_829_212_295_818_019_633_854,
            z: -45_629_392_503_970_208_525_042_048_814_117_258_959,
            dSq: 99_999_999_999_999_999_886_624_093_342_106_115_200
        });
    }

    /// C2: alpha = 1/1.01 (floor ~100 bp under peg), lambda = 300; beta solved for the 99.99% tilt.
    function _eclpParamsC2() internal pure returns (IGyroECLPPool.EclpParams memory) {
        return IGyroECLPPool.EclpParams({
            alpha: 990_099_009_900_990_099,
            beta: 1_000_000_552_916_876_802,
            c: 707_106_781_186_547_524,
            s: 707_106_781_186_547_524,
            lambda: 300_000_000_000_000_000_000
        });
    }

    function _derivedParamsC2() internal pure returns (IGyroECLPPool.DerivedEclpParams memory) {
        return IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({ x: -83_076_997_797_096_709_387_518_705_732_214_686_816, y: 55_661_588_524_054_795_289_637_532_840_583_840_167 }),
            tauBeta: IGyroECLPPool.Vector2({ x: 8_293_750_830_627_766_023_886_238_487_710_783, y: 99_999_999_656_068_485_149_173_817_814_639_350_348 }),
            u: 41_542_645_773_963_668_529_671_944_689_442_651_309,
            v: 77_830_794_090_061_640_131_164_306_868_965_719_890,
            w: 22_169_205_566_006_844_904_633_604_677_715_218_902,
            z: -41_534_352_023_133_040_763_657_461_566_155_111_360,
            dSq: 99_999_999_999_999_999_886_624_093_342_106_115_200
        });
    }

    /// C3: alpha = 1/1.015, lambda = 500 (deeper top, ~40% slower ramp than C1); beta solved for the 99.99% tilt.
    function _eclpParamsC3() internal pure returns (IGyroECLPPool.EclpParams memory) {
        return IGyroECLPPool.EclpParams({
            alpha: 985_221_674_876_847_291,
            beta: 1_000_000_385_747_214_216,
            c: 707_106_781_186_547_524,
            s: 707_106_781_186_547_524,
            lambda: 500_000_000_000_000_000_000
        });
    }

    function _derivedParamsC3() internal pure returns (IGyroECLPPool.DerivedEclpParams memory) {
        return IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({ x: -96_575_238_433_128_612_087_445_572_060_549_518_100, y: 25_946_547_392_367_220_447_493_710_360_267_637_196 }),
            tauBeta: IGyroECLPPool.Vector2({ x: 9_643_678_450_545_580_177_247_953_654_657_943, y: 99_999_999_534_997_328_574_588_614_024_986_545_864 }),
            u: 48_292_441_055_789_578_779_059_417_112_871_671_038,
            v: 62_973_273_463_682_274_439_644_642_451_022_416_666,
            w: 37_026_726_071_315_054_021_568_065_443_271_239_110,
            z: -48_282_797_377_339_033_198_893_102_767_095_491_080,
            dSq: 99_999_999_999_999_999_886_624_093_342_106_115_200
        });
    }

    /// C4 (SELECTED, see the assessment's §7): alpha = 1/1.02 (floor ~196 bp), lambda = 300; beta re-solved.
    function _eclpParamsC4() internal pure returns (IGyroECLPPool.EclpParams memory) {
        return IGyroECLPPool.EclpParams({
            alpha: 980_392_156_862_745_098,
            beta: 1_000_000_630_371_029_932,
            c: 707_106_781_186_547_524,
            s: 707_106_781_186_547_524,
            lambda: 300_000_000_000_000_000_000
        });
    }

    function _derivedParamsC4() internal pure returns (IGyroECLPPool.DerivedEclpParams memory) {
        return IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({ x: -94_773_130_622_350_963_793_914_596_098_909_867_472, y: 31_906_953_976_191_491_143_951_247_353_299_655_382 }),
            tauBeta: IGyroECLPPool.Vector2({ x: 9_455_562_426_453_687_808_195_961_460_162_005, y: 99_999_999_552_961_694_941_282_054_418_046_780_509 }),
            u: 47_391_293_092_388_708_687_131_087_809_789_479_979,
            v: 65_953_476_764_576_592_967_841_298_631_431_128_073,
            w: 34_046_522_788_385_101_860_064_849_635_555_499_105,
            z: -47_381_837_529_962_254_999_333_612_177_959_912_994,
            dSq: 99_999_999_999_999_999_886_624_093_342_106_115_200
        });
    }

    /*//////////////////////////////////////////////////////////////////////////
                                       SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public override {
        super.setUp();

        poolC1 = _createPool(_eclpParamsC1(), _derivedParamsC1(), false, bytes32(uint256(31)));
        poolC2 = _createPool(_eclpParamsC2(), _derivedParamsC2(), false, bytes32(uint256(32)));
        poolC3 = _createPool(_eclpParamsC3(), _derivedParamsC3(), false, bytes32(uint256(33)));
        poolC4 = _createPool(_eclpParamsC4(), _derivedParamsC4(), false, bytes32(uint256(34)));

        address[4] memory pools = [poolC1, poolC2, poolC3, poolC4];
        uint256[4] memory x0s = [X0_C1, X0_C2, X0_C3, X0_C4];
        address[4] memory actors = [lp, arber, exiter, address(this)];
        for (uint256 p = 0; p < 4; ++p) {
            for (uint256 i = 0; i < 4; ++i) {
                vm.prank(actors[i]);
                IERC20(pools[p]).approve(address(router), type(uint256).max);
            }
            router.initialize(pools[p], address(this), _tokens(), _two(x0s[p], Y0));
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CANDIDATE SELECTION
    //////////////////////////////////////////////////////////////////////////*/

    function _useCandidate(uint256 i) internal {
        pool = i == 0 ? poolTilt9999 : i == 1 ? poolC1 : i == 2 ? poolC2 : i == 3 ? poolC3 : poolC4;
    }

    function _candidateLabel(uint256 i) internal pure returns (string memory) {
        if (i == 0) return "A_15bp_lam4000";
        if (i == 1) return "C1_148bp_lam300";
        if (i == 2) return "C2_100bp_lam300";
        if (i == 3) return "C3_148bp_lam500";
        return "C4_196bp_lam300";
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      T8 TESTS
    //////////////////////////////////////////////////////////////////////////*/

    /// Wiring: every candidate initializes on the peg at the 99.99% tilt and keeps the fee shield.
    function test_T8_Candidates_TiltAndFeeShield() public {
        for (uint256 i = 0; i < 5; ++i) {
            _useCandidate(i);
            assertApproxEqAbs(_spotPrice(), 1e18, 1e9, "candidate must initialize on the peg");
            assertApproxEqAbs(_stableShare(), 999_900_000_000_000_000, 1e12, "candidate must hold the 99.99% tilt at the peg");

            (IGyroECLPPool.EclpParams memory params,) = GyroECLPPool(pool).getECLPParams();
            assertLt(uint256(params.beta).mulDown(1e18 - SWAP_FEE), 1e18, "fee shield: beta*(1-fee) must sit below fair");

            (uint256 profit,,) = _optimalArb();
            assertLe(profit, DUST_PROFIT, "a fresh candidate pool must offer no extractable arb");

            _logMetric(
                "t8_wiring",
                string.concat("cand=", _candidateLabel(i), "|beta=", _u(uint256(params.beta)), "|stableShare=", _u(_stableShare()))
            );
        }
    }

    /**
     * @notice The headline battery: drain each candidate to 10/25/50/75/95% of its stables with a real
     *         EXACT_OUT exiter sell, record the exiter's execution haircut and the landed spot discount,
     *         then run the optimal arb to the fee edge and account the restock: arber profit at fair
     *         (the incentive that actually restores exit liquidity), stables re-stocked, and the
     *         volume-weighted restock margin per dollar of stables the arber returned to the pool.
     */
    function test_T8_Candidates_DrainLadder_RestockMargins() public {
        uint256[5] memory fracsPct = [uint256(10), 25, 50, 75, 95];
        for (uint256 i = 0; i < 5; ++i) {
            _useCandidate(i);
            for (uint256 a = 0; a < 5; ++a) {
                (uint256 snap, uint256 ts) = _snapState();

                // Drain: exiter sells ST for exactly fracsPct of the pool's stables. Rates are at their
                // marks (1e18), so raw amounts are fair dollar values as-is.
                uint256 quoteOut = Y0 * fracsPct[a] / 100;
                uint256 stIn = router.swapExactOut(pool, exiter, IERC20(address(st)), IERC20(address(quoteToken)), quoteOut, type(uint256).max);
                uint256 haircutE4 = _bpE4(stIn - quoteOut, stIn); // exiter's all-in shortfall vs fair, bp*1e4
                uint256 discountE4 = uint256(1e18 - int256(_spotPrice())) / 1e10; // landed spot discount, bp*1e4

                // Restock: the optimal arb buys ST back until the edge is inside the fee. Margin is the
                // arber's fair-valued profit per dollar of stables actually returned to the pool.
                (, uint256 qBefore) = _rawBalances();
                uint256 arbProfit = _arbToFeeEdge();
                (, uint256 qAfter) = _rawBalances();
                uint256 restocked = qAfter - qBefore;
                uint256 marginE4 = restocked == 0 ? 0 : _bpE4(arbProfit, restocked);
                uint256 restockedPctE2 = restocked * 1e4 / quoteOut; // % of the drain undone, *1e2

                _logMetric(
                    "t8_ladder",
                    string.concat(
                        "cand=",
                        _candidateLabel(i),
                        "|drainedPct=",
                        _u(fracsPct[a]),
                        "|exiterHaircutBpE4=",
                        _u(haircutE4),
                        "|spotDiscountBpE4=",
                        _u(discountE4),
                        "|arbProfitFair=",
                        _u(arbProfit),
                        "|restockedPctE2=",
                        _u(restockedPctE2),
                        "|restockMarginBpE4=",
                        _u(marginE4)
                    )
                );

                _restoreState(snap, ts);
            }
        }
        _logVerdict(
            "band-width: do wider/looser bands pay arbers a compelling restock margin",
            "MEASURED",
            "see t8_ladder: restockMarginBpE4 is the volume-weighted arb margin net of the 1 bp fee, drift excluded"
        );
    }
}
