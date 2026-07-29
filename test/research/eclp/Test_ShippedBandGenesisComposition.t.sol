// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { IRateProvider } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { PoolRoleAccounts, TokenConfig } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { C4BatteryBase } from "./Test_C4FullBattery.t.sol";

/**
 * @title Test_ShippedBandGenesisComposition
 * @notice The band this suite studies is the C4 research candidate, and the band the repo actually ships for the
 *         snUSD market is a different one. Every seed-sizing number depends on the composition the pool rests at
 *         when the price is at the peg, so this measures that composition for the shipped parameters rather than
 *         carrying the research fixture's 99.99% across.
 *
 *         Parameters are copied from `script/config/MarketDeploymentConfig.sol`, the snUSD market entry.
 *
 *         Regenerate: FOUNDRY_PROFILE=research forge test --match-path test/research/eclp/Test_ShippedBandGenesisComposition.t.sol -vv | grep -E "METRIC|VERDICT"
 */
contract Test_ShippedBandGenesisComposition is C4BatteryBase {
    /// Quote amount every probe pool is seeded with, so the search varies only the senior share amount.
    uint256 internal constant PROBE_QUOTE = 10_000_000e18;

    uint256 internal shippedSalt;

    /// The E-CLP curve parameters the repo ships for the snUSD market.
    function _eclpParamsShipped() internal pure returns (IGyroECLPPool.EclpParams memory) {
        return IGyroECLPPool.EclpParams({
            alpha: 998_502_246_630_054_917,
            beta: 1_000_200_040_008_001_600,
            c: 707_106_781_186_547_524,
            s: 707_106_781_186_547_524,
            lambda: 4_000_000_000_000_000_000_000
        });
    }

    /// The matching high-precision derived parameters the repo ships.
    function _derivedParamsShipped() internal pure returns (IGyroECLPPool.DerivedEclpParams memory) {
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

    /// Creates and initializes a pool on the shipped parameters at the given balances, pointing `pool` at it.
    function _seedShippedPool(uint256 stRaw, uint256 qRaw) internal returns (bool ok) {
        IRateProvider[] memory provs = new IRateProvider[](2);
        provs[0] = IRateProvider(address(stRateProvider));
        provs[1] = IRateProvider(address(quoteRateProvider));
        TokenConfig[] memory cfg = vault.buildTokenConfig(_tokens(), provs);
        PoolRoleAccounts memory roleAccounts;
        address p = factory
            .create(
                "Royco Day shipped E-CLP",
                "RD-ECLP-S",
                cfg,
                _eclpParamsShipped(),
                _derivedParamsShipped(),
                roleAccounts,
                SWAP_FEE,
                address(0),
                false,
                false,
                bytes32(uint256(7000 + shippedSalt++))
            );
        IERC20(p).approve(address(router), type(uint256).max);
        pool = p;
        try router.initialize(p, address(this), _tokens(), _two(stRaw, qRaw)) {
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @notice Measures the value share the shipped band rests at when the price is at the peg
     * @dev Binary searches the senior share amount that puts the spot price at one, against a fixed quote amount,
     *      then reads the quote share of pool value there
     * @dev The spot price falls as senior shares are added, so the search moves the lower bound up when the spot
     *      is above the peg
     */
    function test_TheShippedBandCompositionAtThePeg() public {
        uint256 lo = 1e18;
        uint256 hi = 40_000_000e18;
        uint256 pegST;

        for (uint256 i = 0; i < 60; ++i) {
            uint256 mid = (lo + hi) / 2;
            if (!_seedShippedPool(mid, PROBE_QUOTE)) break;
            uint256 spot = _spotPrice();
            if (spot > 1e18) {
                lo = mid;
            } else {
                hi = mid;
            }
            pegST = mid;
            if (hi - lo <= 1e18) break;
        }

        require(_seedShippedPool(pegST, PROBE_QUOTE), "the peg probe pool must initialize");
        uint256 spotAtPeg = _spotPrice();
        assertApproxEqAbs(spotAtPeg, 1e18, 1e13, "the search must land the spot on the peg");

        uint256 quoteShareWAD = _stableShare();
        uint256 seniorShareWAD = 1e18 - quoteShareWAD;

        // Contrast with the C4 research fixture, whose senior share at the peg is 0.01% of pool value.
        _useC4();
        uint256 c4QuoteShareWAD = _stableShare();

        _logMetric(
            "SHIPPED_BAND_PEG_COMPOSITION",
            string.concat(
                "peg_senior_amount=",
                _u(pegST),
                "|peg_quote_amount=",
                _u(PROBE_QUOTE),
                "|quote_share_wad=",
                _u(quoteShareWAD),
                "|senior_share_wad=",
                _u(seniorShareWAD),
                "|c4_fixture_quote_share_wad=",
                _u(c4QuoteShareWAD)
            )
        );
        _logVerdict(
            "shipped_band_composition",
            "THE_SHIPPED_BAND_IS_NOT_THE_RESEARCH_FIXTURES_TILT",
            "the seed's senior side has to be sized against the shipped band's own resting composition"
        );
    }

    /// The senior share amount that puts the shipped band at the peg against `PROBE_QUOTE`, measured above.
    uint256 internal constant SHIPPED_PEG_ST = 3_915_949_626_111_194_314_237_000;

    /// Attempts an unbalanced add on the active pool.
    function _tryAdd(uint256 stIn, uint256 qIn) internal returns (bool) {
        try router.addLiquidityUnbalanced(pool, address(this), _tokens(), _two(stIn, qIn), 0) returns (uint256[] memory, uint256 bpt) {
            return bpt > 0;
        } catch {
            return false;
        }
    }

    /**
     * @notice The seed fraction boundary holds on the shipped band too, and prices the senior side of the seed
     * @dev The E-CLP invariant scales linearly with the balances, so the boundary is a ratio and does not depend
     *      on the band. What the band changes is how much of the seed has to be senior shares
     */
    function test_TheSeedSizeAndItsSeniorSideOnTheShippedBand() public {
        uint256 depositST = SHIPPED_PEG_ST;
        uint256 depositQuote = PROBE_QUOTE;

        uint256[6] memory divisors = [uint256(2), 4, 5, 8, 10, 100];
        uint256 largestFailing;
        uint256 smallestPassing;
        for (uint256 i = 0; i < divisors.length; ++i) {
            require(_seedShippedPool(depositST / divisors[i], depositQuote / divisors[i]), "probe seed must initialize");
            if (_tryAdd(depositST, depositQuote)) {
                smallestPassing = divisors[i];
            } else if (largestFailing == 0) {
                largestFailing = divisors[i];
            }
        }
        assertEq(smallestPassing, 4, "the shipped band must accept a quarter-sized seed, as the C4 fixture does");
        assertEq(largestFailing, 5, "and reject a fifth-sized one");

        // What the band changes is the senior amount inside that seed.
        uint256 seniorInSeed = depositST / smallestPassing;
        assertGt(seniorInSeed, depositQuote / 100, "the shipped band's seed carries real senior shares, not dust");

        _logMetric(
            "SHIPPED_BAND_SEED",
            string.concat(
                "largest_accepted_divisor=",
                _u(smallestPassing),
                "|smallest_rejected_divisor=",
                _u(largestFailing),
                "|senior_in_seed=",
                _u(seniorInSeed),
                "|quote_in_seed=",
                _u(depositQuote / smallestPassing)
            )
        );
        _logVerdict(
            "shipped_band_seed_size",
            "SAME_QUARTER_BOUNDARY_MUCH_LARGER_SENIOR_SIDE",
            "the seed fraction is a ratio and does not move with the band, but the shipped band's seed is about 28% senior shares"
        );
    }

    /**
     * @notice On the shipped band a one-wei senior seed cannot even be initialized at a useful quote size
     * @dev The band rests near a 72/28 split, so a genesis of one wei of senior shares against millions of quote
     *      sits at the far edge of the band rather than near its resting point
     */
    function test_AOneWeiSeniorGenesisOnTheShippedBand() public {
        // The genesis itself is accepted: a quote-only pool is a legal state on any band.
        assertTrue(_seedShippedPool(1, PROBE_QUOTE / 4), "a one wei senior genesis must still initialize");

        // But a market-sized deposit against it fails, exactly as on the research band.
        assertFalse(_tryAdd(SHIPPED_PEG_ST, PROBE_QUOTE), "a market-sized deposit against a lopsided genesis must fail");

        // A seed at the shipped band's own composition carries it.
        require(_seedShippedPool(SHIPPED_PEG_ST / 4, PROBE_QUOTE / 4), "the composition seed must initialize");
        assertTrue(_tryAdd(SHIPPED_PEG_ST, PROBE_QUOTE), "and it must carry the market-sized deposit");

        _logVerdict(
            "shipped_band_one_wei_genesis",
            "A_QUARTER_SIZED_QUOTE_SEED_IS_NOT_ENOUGH_WHEN_SIZED_ON_THE_QUOTE_AMOUNT_ALONE",
            "the shipped band's deposit carries 28% of its value in senior shares, so a quote-only seed has to cover that too"
        );
    }

    /**
     * @notice Whether a genesis of one wei of senior shares plus quote alone can carry the first deposit on the
     *         shipped band, and how much quote that takes
     * @dev This is the question behind the team's stated obstacle: the market cannot mint senior shares before its
     *      kernel exists, so a seed needing no meaningful senior amount is worth a great deal to them
     */
    function test_HowMuchQuoteAOneWeiSeniorGenesisNeedsOnTheShippedBand() public {
        uint256 depositST = SHIPPED_PEG_ST;
        uint256 depositQuote = PROBE_QUOTE;
        // Senior shares price at about one in quote across this band, so the deposit's value is the sum.
        uint256 depositValue = depositQuote + depositST;

        uint256[7] memory percents = [uint256(25), 30, 35, 40, 50, 75, 100];
        uint256 smallestPassing;
        for (uint256 i = 0; i < percents.length; ++i) {
            require(_seedShippedPool(1, (depositValue * percents[i]) / 100), "probe seed must initialize");
            if (_tryAdd(depositST, depositQuote)) {
                smallestPassing = percents[i];
                break;
            }
        }

        _logMetric(
            "SHIPPED_BAND_QUOTE_ONLY_SEED",
            string.concat(
                "deposit_value=",
                _u(depositValue),
                "|smallest_passing_percent=",
                _u(smallestPassing),
                "|quote_needed=",
                _u(smallestPassing == 0 ? 0 : (depositValue * smallestPassing) / 100),
                "|composition_seed_senior=",
                _u(depositST / 4),
                "|composition_seed_quote=",
                _u(depositQuote / 4)
            )
        );
        _logVerdict(
            "shipped_band_quote_only_seed",
            smallestPassing == 0 ? "NO_QUOTE_ONLY_SEED_CARRIES_IT" : "A_QUOTE_ONLY_SEED_CARRIES_IT_AT_A_PRICE",
            "measures whether the senior side of the genesis can be one wei on the band the repo actually ships"
        );
    }
}
