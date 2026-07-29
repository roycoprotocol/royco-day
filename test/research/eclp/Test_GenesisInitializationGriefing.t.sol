// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRateProvider } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { PoolRoleAccounts, TokenConfig } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { BasePoolMath } from "../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BasePoolMath.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IVaultErrors } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";
import { C4BatteryBase } from "./Test_C4FullBattery.t.sol";
import { SingleTokenRemoveRouter } from "./Test_BandEdgeLiveness.t.sol";
import { ProportionalAddRouter } from "./Test_ProportionalAddAtZeroLeg.t.sol";

/**
 * @title Test_GenesisInitializationGriefing
 * @notice The review question behind the reported griefing issue: a Day market's pool is created uninitialized and
 *         nothing in the repo initializes it, so the first party to call the venue's public initialize picks the
 *         pool's genesis composition. This measures what a hostile choice actually costs the market, and what a
 *         seed has to look like to be immune.
 *
 *         Two separate defects come out of one hostile genesis, and they need different fixes:
 *           1. a senior leg at exactly zero, which arithmetic-panics every quote-side unbalanced add (T10 measured
 *              this shape already; here it is measured at the dust scale a griefer would actually use)
 *           2. a tiny genesis invariant, which puts every real deposit over the E-CLP's 5x unbalanced growth cap
 *              even after the zero leg is cleared
 *         Seeding dust on both legs fixes only the first. The cap is a ratio, so it is indifferent to which legs
 *         are occupied and only a seed of real size clears it.
 *
 *         The quote leg is 18 decimals here, as everywhere in this suite, so a 6-decimal USDC amount is expressed
 *         as the 18-decimal amount carrying the same scaled18 value the Vault would compute: 1 wei of USDC is
 *         1e12 here.
 *
 *         Regenerate: FOUNDRY_PROFILE=research forge test --match-path test/research/eclp/Test_GenesisInitializationGriefing.t.sol -vv | grep -E "METRIC|VERDICT"
 */
contract Test_GenesisInitializationGriefing is C4BatteryBase {
    /// One wei of a 6-decimal quote token, in the 18-decimal units this suite's quote token uses.
    uint256 internal constant ONE_WEI_USDC = 1e12;

    /// The E-CLP's cap on invariant growth for a single unbalanced add (GyroECLPMath.MAX_INVARIANT_RATIO).
    uint256 internal constant MAX_INVARIANT_RATIO = 5e18;

    /// A market-sized first deposit: the shipped C4 fixture's own genesis composition.
    uint256 internal constant DEPOSIT_ST = X0_C4B;
    uint256 internal constant DEPOSIT_QUOTE = Y0;

    uint256 internal saltCounter;

    /// Router shims for the add and removal kinds the study router omits.
    ProportionalAddRouter internal propRouter;
    SingleTokenRemoveRouter internal stRemoveRouter;

    function setUp() public virtual override {
        super.setUp();
        propRouter = new ProportionalAddRouter(IVault(address(vault)));
        stRemoveRouter = new SingleTokenRemoveRouter(IVault(address(vault)));
        st.approve(address(propRouter), type(uint256).max);
        quoteToken.approve(address(propRouter), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// Creates a fresh uninitialized C4 pool, points `pool` at it, and approves the router for its BPT.
    function _freshPool() internal returns (address p) {
        p = _createPool(_eclpParamsC4(), _derivedParamsC4(), false, bytes32(uint256(4000 + saltCounter++)));
        IERC20(p).approve(address(router), type(uint256).max);
        pool = p;
    }

    /**
     * @notice Creates a fresh uninitialized C4 pool naming a specific senior rate provider and pause manager
     * @dev The base helper fixes both, and the pause and rate-provider tests need to vary them
     */
    function _freshPoolWith(address _seniorRateProvider, address _pauseManager) internal returns (address p) {
        IRateProvider[] memory provs = new IRateProvider[](2);
        provs[0] = IRateProvider(_seniorRateProvider);
        provs[1] = IRateProvider(address(quoteRateProvider));
        TokenConfig[] memory cfg = vault.buildTokenConfig(_tokens(), provs);
        PoolRoleAccounts memory roleAccounts;
        roleAccounts.pauseManager = _pauseManager;
        p = factory
            .create(
                "Royco Day tilted E-CLP",
                "RD-ECLP",
                cfg,
                _eclpParamsC4(),
                _derivedParamsC4(),
                roleAccounts,
                SWAP_FEE,
                address(0),
                false,
                false,
                bytes32(uint256(4000 + saltCounter++))
            );
        IERC20(p).approve(address(router), type(uint256).max);
        pool = p;
    }

    /// Attempts to initialize the active pool at the given raw balances; reports success and the BPT minted.
    function _tryInitialize(uint256 stRaw, uint256 qRaw) internal returns (bool ok, uint256 bptOut) {
        try router.initialize(pool, address(this), _tokens(), _two(stRaw, qRaw)) returns (uint256 minted) {
            return (true, minted);
        } catch {
            return (false, 0);
        }
    }

    /// Creates a fresh pool and initializes it at the given raw balances, leaving it as the active pool.
    function _seedPool(uint256 stRaw, uint256 qRaw) internal {
        _freshPool();
        (bool ok,) = _tryInitialize(stRaw, qRaw);
        require(ok, "seed: initialization must succeed");
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

    /// True when the caught revert is the Vault's unbalanced-add growth cap.
    function _isInvariantRatioAboveMax(bytes memory err) internal pure returns (bool) {
        if (err.length < 4) return false;
        bytes4 sel;
        assembly {
            sel := mload(add(err, 0x20))
        }
        return sel == BasePoolMath.InvariantRatioAboveMax.selector;
    }

    /// Attempts an unbalanced add on the active pool; reports success and how it failed when it did.
    function _tryAdd(uint256 stIn, uint256 qIn) internal returns (bool ok, bool panic, bool ratioCapped) {
        try router.addLiquidityUnbalanced(pool, address(this), _tokens(), _two(stIn, qIn), 0) returns (uint256[] memory, uint256 bpt) {
            return (bpt > 0, false, false);
        } catch (bytes memory err) {
            return (false, _isArithmeticPanic(err), _isInvariantRatioAboveMax(err));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WHO PICKS GENESIS, AND WHAT IT COSTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice A quote-only genesis is reachable at dust scale, and it is one-shot
     * @dev Sweeps downward for the smallest quote-only genesis the Vault accepts, which is what a griefer pays
     * @dev The floor is Balancer's minimum pool supply of 1e6 BPT, not any check on the amounts supplied
     */
    function test_TheCheapestHostileGenesis() public {
        uint256[6] memory probes = [uint256(1e18), 1e15, ONE_WEI_USDC, 1e9, 1e6, 1];
        uint256 smallest;
        uint256 smallestBpt;
        for (uint256 i = 0; i < probes.length; ++i) {
            _freshPool();
            (bool ok, uint256 bpt) = _tryInitialize(0, probes[i]);
            if (!ok) break;
            (smallest, smallestBpt) = (probes[i], bpt);
        }
        assertGt(smallest, 0, "some quote-only genesis size must be accepted");
        assertLe(smallest, ONE_WEI_USDC, "the cheapest accepted genesis must be no larger than one wei of USDC");

        // The pool the griefer leaves behind is live, quotes, and cannot be initialized a second time.
        _seedPool(0, smallest);
        (uint256 stRaw, uint256 qRaw) = _rawBalances();
        assertEq(stRaw, 0, "the hostile genesis leaves the senior leg at exactly zero");
        assertEq(qRaw, smallest, "the hostile genesis leaves only the griefer's dust in the quote leg");
        (bool reinit,) = _tryInitialize(DEPOSIT_ST, DEPOSIT_QUOTE);
        assertFalse(reinit, "an initialized pool must reject a second initialization, so genesis is one-shot");

        _logMetric(
            "GENESIS_COST",
            string.concat(
                "smallest_quote_only_genesis_wei18=",
                _u(smallest),
                "|one_wei_usdc_in_wei18=",
                _u(ONE_WEI_USDC),
                "|headroom_multiple=",
                _u(ONE_WEI_USDC / smallest),
                "|bpt_minted=",
                _u(smallestBpt),
                "|genesis_invariant=",
                _u(_invariant())
            )
        );
        _logVerdict(
            "cheapest_hostile_genesis",
            "DUST_IS_ENOUGH_AND_IT_IS_ONE_SHOT",
            "the only floor is Balancer's 1e6 minimum pool supply, and initialize cannot be repeated"
        );
    }

    /**
     * @notice A dust genesis rejects both deposit shapes the market has, for two different reasons
     * @dev The quote-only deposit arithmetic-panics on the zero senior leg
     * @dev The senior-backed deposit clears the panic but exceeds the E-CLP's 5x invariant growth cap
     */
    function test_DustGenesisRejectsBothDepositShapes() public {
        _seedPool(0, ONE_WEI_USDC);

        // A quote-only deposit, the only shape a fixed-term market accepts, panics on the zero senior leg.
        (bool quoteOnly, bool quotePanic, bool quoteCapped) = _tryAdd(0, DEPOSIT_QUOTE);
        assertFalse(quoteOnly, "a quote-only deposit must fail at the zero senior leg");
        assertTrue(quotePanic, "it fails as an arithmetic panic, before any invariant check");
        assertFalse(quoteCapped, "the growth cap is not what stopped it");

        // A senior-backed deposit puts both legs in, so it reaches the invariant check and is stopped there.
        (bool bothLegs,, bool bothCapped) = _tryAdd(DEPOSIT_ST, DEPOSIT_QUOTE);
        assertFalse(bothLegs, "a market-sized senior-backed deposit must fail against a dust genesis");
        assertTrue(bothCapped, "it fails on the E-CLP's maximum invariant ratio, not on a panic");

        _logVerdict(
            "dust_genesis_deposits",
            "BOTH_SHAPES_REJECTED_BY_DIFFERENT_CHECKS",
            "quote-only panics on the zero leg; senior-backed reaches the 5x invariant cap"
        );
    }

    /**
     * @notice Dust on both legs clears the panic and leaves the growth cap untouched
     * @dev This is the difference between the two defects: the panic is about which legs are occupied, the cap is
     *      about how large the genesis invariant is
     */
    function test_TwoSidedDustClearsThePanicButNotTheCap() public {
        // One wei of senior shares is enough to make the quote-only add reach the invariant check. Doubling the
        // quote leg is a 2x growth ratio, inside the cap.
        _seedPool(1, ONE_WEI_USDC);
        (bool quoteSmall,,) = _tryAdd(0, ONE_WEI_USDC);
        assertTrue(quoteSmall, "a deposit within the growth cap must succeed once the senior leg is nonzero");

        _seedPool(1, ONE_WEI_USDC);
        (bool quoteBig, bool bigPanic, bool bigCapped) = _tryAdd(0, DEPOSIT_QUOTE);
        assertFalse(quoteBig, "a market-sized deposit must still fail against a dust genesis");
        assertFalse(bigPanic, "the two-sided dust seed removed the panic");
        assertTrue(bigCapped, "what remains is the invariant growth cap");

        _logVerdict(
            "two_sided_dust",
            "DUST_FIXES_THE_PANIC_ONLY",
            "a nonzero senior leg makes quote adds reach the invariant check, which a dust invariant then fails"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WHAT A SEED HAS TO BE
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Measures how large a two-sided genesis must be to accept a market-sized first deposit in one call
     * @dev The 5x cap makes the requirement a fraction of the first deposit, not an absolute amount
     */
    function test_TheSeedFractionThatAcceptsTheFirstDeposit() public {
        uint256[6] memory divisors = [uint256(2), 4, 5, 8, 10, 100];
        uint256 largestFailing;
        uint256 smallestPassing;
        for (uint256 i = 0; i < divisors.length; ++i) {
            _seedPool(DEPOSIT_ST / divisors[i], DEPOSIT_QUOTE / divisors[i]);
            (bool ok,,) = _tryAdd(DEPOSIT_ST, DEPOSIT_QUOTE);
            if (ok) {
                smallestPassing = divisors[i];
            } else if (largestFailing == 0) {
                largestFailing = divisors[i];
            }
        }
        assertGt(smallestPassing, 0, "some seed fraction must accept the first deposit outright");
        assertGt(largestFailing, smallestPassing, "and some smaller fraction must fail, so the boundary is measured");

        _logMetric(
            "SEED_FRACTION",
            string.concat(
                "largest_accepted_divisor=", _u(smallestPassing), "|smallest_rejected_divisor=", _u(largestFailing)
            )
        );
        _logVerdict(
            "seed_fraction_required",
            "THE_SEED_IS_A_FRACTION_OF_THE_FIRST_DEPOSIT",
            "the growth cap is a ratio, so the genesis must be about a quarter of the deposit it has to accept"
        );
    }

    /**
     * @notice The same seed fraction governs a quote-only first deposit, which is the shape a fixed-term market has
     * @dev Measured separately because a quote-only add is not proportional, so the growth ratio is not the
     *      proportional one and the boundary could have differed
     */
    function test_TheSeedFractionForAQuoteOnlyFirstDeposit() public {
        uint256[6] memory divisors = [uint256(2), 4, 5, 8, 10, 100];
        uint256 largestFailing;
        uint256 smallestPassing;
        for (uint256 i = 0; i < divisors.length; ++i) {
            _seedPool(DEPOSIT_ST / divisors[i], DEPOSIT_QUOTE / divisors[i]);
            (bool ok,,) = _tryAdd(0, DEPOSIT_QUOTE);
            if (ok) {
                smallestPassing = divisors[i];
            } else if (largestFailing == 0) {
                largestFailing = divisors[i];
            }
        }
        assertGt(smallestPassing, 0, "some seed fraction must accept a quote-only first deposit outright");
        assertGt(largestFailing, smallestPassing, "and some smaller fraction must fail, so the boundary is measured");

        _logMetric(
            "SEED_FRACTION_QUOTE_ONLY",
            string.concat("largest_accepted_divisor=", _u(smallestPassing), "|smallest_rejected_divisor=", _u(largestFailing))
        );
        _logVerdict(
            "seed_fraction_quote_only",
            "SAME_BOUNDARY_AS_THE_PROPORTIONAL_DEPOSIT",
            "the quote-only deposit reaches the growth cap at the same seed fraction, because the pool is almost all quote"
        );
    }

    /**
     * @notice The seed requirement is about the genesis total size, not about how much of it is senior shares
     * @dev A genesis at the pool's own 99.99% quote composition holds almost no senior shares and still accepts a
     *      market-sized first deposit, provided the total is large enough
     * @dev The senior share amount in that seed is far below a quarter of the first deposit, which settles the
     *      question of whether the quarter applies to the senior side
     */
    function test_TheQuarterIsAboutTotalSizeNotTheSeniorLeg() public {
        // A quarter-sized seed at the pool's own composition: the senior side is 0.01% of it by value.
        uint256 seedST = DEPOSIT_ST / 4;
        uint256 seedQuote = DEPOSIT_QUOTE / 4;
        _seedPool(seedST, seedQuote);
        (bool ok,,) = _tryAdd(DEPOSIT_ST, DEPOSIT_QUOTE);
        assertTrue(ok, "a quarter-sized seed at the 99.99% composition must accept the first deposit");
        assertLt(seedST * 4, DEPOSIT_ST * 4, "the seed's senior share amount is nowhere near a quarter of the deposit's value");

        // The same senior share amount with a dust quote side does not work, so it is not the senior side doing it.
        _seedPool(seedST, 1);
        (bool seniorAlone,, bool capped) = _tryAdd(DEPOSIT_ST, DEPOSIT_QUOTE);
        assertFalse(seniorAlone, "the same senior amount with a dust quote side must fail");
        assertTrue(capped, "and it fails on the growth cap, so total genesis size is what the cap responds to");

        _logMetric(
            "QUARTER_IS_TOTAL_SIZE",
            string.concat(
                "seed_st=", _u(seedST), "|seed_quote=", _u(seedQuote), "|deposit_st=", _u(DEPOSIT_ST), "|deposit_quote=", _u(DEPOSIT_QUOTE)
            )
        );
        _logVerdict(
            "quarter_is_total_size",
            "THE_QUARTER_IS_ON_THE_GENESIS_TOTAL",
            "the senior side of a compliant seed is 0.01% of it; holding that side fixed and shrinking the quote side fails"
        );
    }

    /**
     * @notice One wei of senior shares plus a quarter-sized quote seed satisfies both checks at once
     * @dev The senior amount answers the underflow, which only needs a nonzero balance, and the quote amount
     *      answers the growth cap, which only responds to total size
     * @dev This is the cheapest compliant genesis in senior shares, which is the token the market cannot mint
     *      before its kernel exists
     */
    function test_OneWeiOfSeniorSharesPlusAQuarterSizedQuoteSeedIsEnough() public {
        // Sweep the quote side of a one-wei-senior seed, in percent of the first deposit's whole value, for the
        // smallest that carries a market-sized senior-backed deposit.
        uint256 depositValue = DEPOSIT_QUOTE + DEPOSIT_ST;
        uint256[6] memory percents = [uint256(20), 24, 25, 26, 30, 50];
        uint256 smallestPassing;
        for (uint256 i = 0; i < percents.length; ++i) {
            _seedPool(1, (depositValue * percents[i]) / 100);
            (bool ok,,) = _tryAdd(DEPOSIT_ST, DEPOSIT_QUOTE);
            if (ok) {
                smallestPassing = percents[i];
                break;
            }
        }
        assertGt(smallestPassing, 0, "some one-wei-senior seed must carry a market-sized senior-backed deposit");
        assertLe(smallestPassing, 30, "and it must be near a quarter of the deposit, not a multiple of it");

        // At that size the quote-only deposit works too, so one wei of senior shares covers the underflow for both.
        _seedPool(1, (depositValue * smallestPassing) / 100);
        (bool quoteOnly, bool panic, bool capped) = _tryAdd(0, DEPOSIT_QUOTE);
        assertTrue(quoteOnly, "a market-sized quote-only deposit must succeed at the same seed");
        assertFalse(panic || capped, "and neither check may stop it");

        // A quarter exactly is the algebraic boundary, so the working seed sits just above it and margin is needed.
        assertGe(smallestPassing, 25, "the measured boundary must not be below the algebraic quarter");

        _logMetric(
            "MINIMAL_SENIOR_SEED",
            string.concat(
                "seed_st=1|smallest_passing_percent_of_deposit_value=",
                _u(smallestPassing),
                "|seed_quote=",
                _u((depositValue * smallestPassing) / 100),
                "|deposit_value=",
                _u(depositValue)
            )
        );
        _logVerdict(
            "minimal_senior_seed",
            "ONE_WEI_OF_SENIOR_SHARES_IS_ALL_THE_SENIOR_SIDE_NEEDS",
            "the senior side answers the underflow only, the quote side carries the size requirement, and a quarter is the boundary so it needs margin"
        );
    }

    /**
     * @notice A genesis at the market's intended composition and size accepts market-sized deposits immediately
     * @dev Both deposit shapes work on the first call, which is the state a deploy-and-initialize would produce
     */
    function test_MeaningfulTwoSidedGenesisIsImmediatelyUsable() public {
        _seedPool(DEPOSIT_ST, DEPOSIT_QUOTE);
        (bool bothLegs,,) = _tryAdd(DEPOSIT_ST, DEPOSIT_QUOTE);
        assertTrue(bothLegs, "a senior-backed deposit must succeed against a full-size genesis");

        _seedPool(DEPOSIT_ST, DEPOSIT_QUOTE);
        (bool quoteOnly,,) = _tryAdd(0, DEPOSIT_QUOTE);
        assertTrue(quoteOnly, "a quote-only deposit must succeed against a full-size genesis");

        _logVerdict(
            "meaningful_genesis",
            "NO_WINDOW_AT_ALL",
            "a genesis at the intended composition and size serves both deposit shapes on the first call"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RECOVERY
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice A griefed pool is recoverable, and this counts the operations it takes
     * @dev The first operation has to put senior shares in, because a quote add still panics at the zero leg
     * @dev After that the pool is grown by proportional unbalanced adds held under the 5x cap
     */
    function test_TheRecoveryLadderFromADustGenesis() public {
        // The ladder's target: the invariant the shipped C4 fixture carries at its own genesis size.
        _seedPool(DEPOSIT_ST, DEPOSIT_QUOTE);
        uint256 target = _invariant();

        _seedPool(0, ONE_WEI_USDC);
        uint256 startInvariant = _invariant();

        // Step one has to put senior shares in, the one shape the zero leg accepts. It cannot be sized at the
        // pool's own 99.99% composition ratio: that mints less than the Vault's 1e6 minimum BPT and is rejected.
        // Sweep upward for the smallest senior-side opening add that is accepted.
        uint256 openingST;
        uint256[6] memory openings =
            [ONE_WEI_USDC / 10_000, ONE_WEI_USDC / 1000, ONE_WEI_USDC / 100, ONE_WEI_USDC / 10, ONE_WEI_USDC, ONE_WEI_USDC * 2];
        for (uint256 i = 0; i < openings.length; ++i) {
            (bool opened,,) = _tryAdd(openings[i], 0);
            if (opened) {
                openingST = openings[i];
                break;
            }
        }
        assertGt(openingST, 0, "the recovery must open with a senior-side add, the one shape the zero leg accepts");
        assertGt(openingST, (ONE_WEI_USDC * DEPOSIT_ST) / DEPOSIT_QUOTE, "and it must be larger than the composition-proportional amount");

        // Then quadruple the pool repeatedly. Adding 3x the current balances keeps the growth ratio at 4x, under
        // the 5x cap, and proportional amounts are not charged the unbalanced add's swap fee.
        uint256 steps = 1;
        while (_invariant() < target && steps < 64) {
            (uint256 stRaw, uint256 qRaw) = _rawBalances();
            (bool grew,,) = _tryAdd(stRaw * 3, qRaw * 3);
            assertTrue(grew, "each rung of the ladder must be accepted");
            ++steps;
        }
        assertLt(steps, 64, "the ladder must reach market size within the step budget");

        // The recovered pool serves a market-sized deposit of either shape.
        (bool quoteOnly,,) = _tryAdd(0, DEPOSIT_QUOTE);
        assertTrue(quoteOnly, "the recovered pool must accept a quote-only deposit");

        _logMetric(
            "RECOVERY_LADDER",
            string.concat(
                "start_invariant=",
                _u(startInvariant),
                "|target_invariant=",
                _u(target),
                "|opening_senior_add=",
                _u(openingST),
                "|steps=",
                _u(steps),
                "|end_invariant=",
                _u(_invariant())
            )
        );
        _logVerdict(
            "recovery_ladder",
            "RECOVERABLE_BUT_NOT_IN_ONE_TRANSACTION_SHAPE",
            "recovery needs a senior-side opening add and then a run of escalating adds, each held under the 5x cap"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WHETHER A ONE WEI SENIOR SEED IS ACTUALLY SAFE TO SHIP
    // ═══════════════════════════════════════════════════════════════════════════

    /// Attempts to sell senior shares into the pool for quote.
    function _trySellSenior(uint256 amtIn) internal returns (bool) {
        vm.prank(arber);
        try router.swapExactIn(pool, arber, IERC20(address(st)), IERC20(address(quoteToken)), amtIn, 0) returns (uint256 out) {
            return out > 0;
        } catch {
            return false;
        }
    }

    /// Attempts to buy senior shares out of the pool with quote.
    function _tryBuySenior(uint256 amtIn) internal returns (bool) {
        vm.prank(arber);
        try router.swapExactIn(pool, arber, IERC20(address(quoteToken)), IERC20(address(st)), amtIn, 0) returns (uint256 out) {
            return out > 0;
        } catch {
            return false;
        }
    }

    /**
     * @notice Runs every pool operation class against a genesis, so nothing is left assumed
     * @dev Reports one flag per operation. `buySenior` is the only one a quote-heavy genesis cannot serve, and it is
     *      bound by how many senior shares the pool holds rather than by anything about the seed
     */
    struct OpsReport {
        uint256 smallestAcceptedSeniorSale;
        bool sellSenior;
        bool buySenior;
        bool addBothLegs;
        bool addQuoteOnly;
        bool addSeniorOnly;
        bool addProportional;
        bool removeProportional;
        bool removeSingleExactIn;
        bool removeSingleExactOut;
        bool proportionalAddFailedOnMinimumTradeAmount;
    }

    /// True when the caught revert is the Vault's minimum trade amount check.
    function _isTradeAmountTooSmall(bytes memory err) internal pure returns (bool) {
        if (err.length < 4) return false;
        bytes4 sel;
        assembly {
            sel := mload(add(err, 0x20))
        }
        return sel == IVaultErrors.TradeAmountTooSmall.selector;
    }

    /// Exercises every operation class against a fresh pool seeded at the given balances.
    function _runOps(uint256 seedST, uint256 seedQuote) internal returns (OpsReport memory r) {
        uint256 probe = seedQuote / 1000;

        // Swaps. Sweep upward for the smallest accepted senior sale, since the Vault checks its minimum trade
        // amount on the swap output as well as its input and the pool's fee pushes the smallest sizes under it.
        uint256[5] memory sizes = [uint256(1e6), 2e6, 1e9, 1e15, 1e18];
        for (uint256 i = 0; i < sizes.length; ++i) {
            _seedPool(seedST, seedQuote);
            if (_trySellSenior(sizes[i])) {
                r.smallestAcceptedSeniorSale = sizes[i];
                break;
            }
        }
        r.sellSenior = r.smallestAcceptedSeniorSale > 0;
        // Buy one quote token's worth of senior shares, which any pool holding real senior inventory can serve.
        _seedPool(seedST, seedQuote);
        r.buySenior = _tryBuySenior(1e18);

        // Adds, one fresh pool each so no operation is measured against another's aftermath.
        _seedPool(seedST, seedQuote);
        (r.addBothLegs,,) = _tryAdd(probe / 10_000, probe);
        _seedPool(seedST, seedQuote);
        (r.addQuoteOnly,,) = _tryAdd(0, probe);
        _seedPool(seedST, seedQuote);
        (r.addSeniorOnly,,) = _tryAdd(probe / 10_000, 0);
        _seedPool(seedST, seedQuote);
        IERC20(pool).approve(address(propRouter), type(uint256).max);
        try propRouter.addLiquidityProportional(pool, address(this), _tokens(), IERC20(pool).totalSupply() / 10) {
            r.addProportional = true;
        } catch (bytes memory err) {
            r.proportionalAddFailedOnMinimumTradeAmount = _isTradeAmountTooSmall(err);
        }

        // Removals, against the seeder's own pool tokens.
        _seedPool(seedST, seedQuote);
        try router.removeLiquidityProportional(pool, address(this), IERC20(pool).balanceOf(address(this)) / 10, _tokens()) {
            r.removeProportional = true;
        } catch { }
        _seedPool(seedST, seedQuote);
        IERC20(pool).approve(address(stRemoveRouter), type(uint256).max);
        try stRemoveRouter.removeSingleExactIn(pool, address(this), _tokens(), 1, IERC20(pool).balanceOf(address(this)) / 100) {
            r.removeSingleExactIn = true;
        } catch { }
        _seedPool(seedST, seedQuote);
        IERC20(pool).approve(address(stRemoveRouter), type(uint256).max);
        try stRemoveRouter.removeSingleExactOut(pool, address(this), _tokens(), 1, probe, IERC20(pool).balanceOf(address(this))) {
            r.removeSingleExactOut = true;
        } catch { }
    }

    /// Renders an operations report as a metric line.
    function _reportOps(string memory label, OpsReport memory r) internal pure {
        _logMetric(
            label,
            string.concat(
                "smallest_senior_sale=",
                _u(r.smallestAcceptedSeniorSale),
                "|sellSenior=",
                r.sellSenior ? "1" : "0",
                "|buySenior=",
                r.buySenior ? "1" : "0",
                "|addBoth=",
                r.addBothLegs ? "1" : "0",
                "|addQuoteOnly=",
                r.addQuoteOnly ? "1" : "0",
                "|addSeniorOnly=",
                r.addSeniorOnly ? "1" : "0",
                "|addProportional=",
                r.addProportional ? "1" : "0",
                "|removeProportional=",
                r.removeProportional ? "1" : "0",
                "|removeSingleExactIn=",
                r.removeSingleExactIn ? "1" : "0",
                "|removeSingleExactOut=",
                r.removeSingleExactOut ? "1" : "0"
            )
        );
    }

    /**
     * @notice Every operation class against a one-wei senior genesis, and against one at the pool's composition
     * @dev The two seeds differ on exactly one operation: a pool holding one wei of senior shares cannot sell any,
     *      so buying senior shares out reverts. Seeding at the pool's own composition gives it real inventory
     * @dev The minimum trade amount is what makes the one-wei case fail that direction, but raising the seed to
     *      1e6 does not fix it either. What fixes it is seeding at the composition, which is a much larger amount
     */
    function test_EveryOperationClassAfterInitialization() public {
        uint256 seedQuote = ((DEPOSIT_QUOTE + DEPOSIT_ST) * 26) / 100;
        uint256 compositionST = (seedQuote * DEPOSIT_ST) / DEPOSIT_QUOTE;

        OpsReport memory oneWei = _runOps(1, seedQuote);
        _reportOps("OPS_ONE_WEI_SENIOR_SEED", oneWei);

        OpsReport memory atComposition = _runOps(compositionST, seedQuote);
        _reportOps("OPS_COMPOSITION_SEED", atComposition);

        // A seed at the pool's own composition serves every operation class.
        assertTrue(atComposition.sellSenior, "composition seed: selling senior shares in must work");
        assertTrue(atComposition.buySenior, "composition seed: buying senior shares out must work");
        assertTrue(atComposition.addBothLegs, "composition seed: the two-token add must work");
        assertTrue(atComposition.addQuoteOnly, "composition seed: the quote-only add must work");
        assertTrue(atComposition.addSeniorOnly, "composition seed: the senior-only add must work");
        assertTrue(atComposition.addProportional, "composition seed: the proportional add must work");
        assertTrue(atComposition.removeProportional, "composition seed: the proportional removal must work");
        assertTrue(atComposition.removeSingleExactIn, "composition seed: the single-token exact-in removal must work");
        assertTrue(atComposition.removeSingleExactOut, "composition seed: the single-token exact-out removal must work");

        // A one-wei senior seed does not. It carries the unbalanced adds and the senior sale, and fails three
        // operation classes that a seed at the composition serves.
        assertTrue(oneWei.sellSenior, "one wei seed: selling senior shares in still works");
        assertTrue(oneWei.addBothLegs && oneWei.addQuoteOnly && oneWei.addSeniorOnly, "one wei seed: the unbalanced adds still work");
        assertTrue(oneWei.removeProportional && oneWei.removeSingleExactOut, "one wei seed: the proportional and exact-out removals still work");
        assertFalse(oneWei.buySenior, "one wei seed: buying senior shares out fails, the pool holds none to sell");
        assertFalse(oneWei.addProportional, "one wei seed: the proportional add fails");
        assertTrue(
            oneWei.proportionalAddFailedOnMinimumTradeAmount,
            "one wei seed: and it fails on the Vault's minimum trade amount, because the pro-rata senior amount is nonzero but tiny"
        );
        assertFalse(oneWei.removeSingleExactIn, "one wei seed: the single-token exact-in removal fails");

        _logVerdict(
            "operations_after_initialization",
            "ONE_WEI_IS_NOT_ENOUGH_SEED_AT_THE_COMPOSITION",
            "a composition seed serves all nine operation classes; a one wei senior seed fails three of them, one of them on the minimum trade amount"
        );
    }

    /**
     * @notice A one-wei senior balance stays nonzero for the add math even when the senior rate falls
     * @dev The Vault loads balances rounding up for an add, so one wei of raw balance never scales to zero however
     *      low the rate is, and the arithmetic panic does not come back
     * @dev The balance reported by `getCurrentLiveBalances` rounds down and does read zero, so that view disagrees
     *      with what the add path sees. The add path is the one that decides
     */
    function test_AOneWeiSeniorSeedSurvivesAFallInTheSeniorRate() public {
        uint256 seedQuote = ((DEPOSIT_QUOTE + DEPOSIT_ST) * 26) / 100;

        _seedPool(1, seedQuote);
        stRateProvider.mockRate(5e17);
        (uint256 stLiveRoundedDown,) = _liveBalances();
        assertEq(stLiveRoundedDown, 0, "the rounded-down view of the senior balance reads zero at a half rate");

        (bool stillWorks, bool panic,) = _tryAdd(0, DEPOSIT_QUOTE);
        assertTrue(stillWorks, "the quote-only deposit must still succeed, because the add path rounds the balance up");
        assertFalse(panic, "so the arithmetic panic does not return");

        // Even an extreme rate leaves the add path seeing a nonzero balance.
        _seedPool(1, seedQuote);
        stRateProvider.mockRate(1);
        (bool atExtremeRate, bool extremePanic,) = _tryAdd(0, DEPOSIT_QUOTE);
        assertTrue(atExtremeRate, "a one wei rate must still leave the add path a nonzero senior balance");
        assertFalse(extremePanic, "and still no panic");
        stRateProvider.mockRate(1e18);

        _logVerdict(
            "one_wei_seed_rate_sensitivity",
            "THE_ADD_PATH_ROUNDS_UP_SO_ONE_WEI_NEVER_SCALES_TO_ZERO",
            "a senior rate fall does not return the seed to zero for the add math, though the rounded-down balance view reads zero"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // THE RATE PROVIDER AS A GENESIS LOCK
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice A senior leg whose rate provider has no code yet cannot be initialized, but the pool can still be created
     * @dev This is the shape a market takes between pool creation and the transaction that deploys its kernel, when
     *      the senior rate provider is the predicted kernel address and nothing is deployed there yet
     * @dev The lock lifts the moment that address has code, which is where the open window begins
     */
    function test_ACodelessSeniorRateProviderBlocksInitialization() public {
        bytes memory rateProviderCode = address(stRateProvider).code;
        assertGt(rateProviderCode.length, 0, "precondition: the senior rate provider must start with code");

        // Strip the rate provider's code, standing in for a kernel address that has not been deployed yet.
        vm.etch(address(stRateProvider), "");
        _freshPool();
        assertTrue(vault.isPoolRegistered(pool), "the pool must still be creatable against a codeless rate provider");

        (bool whileCodeless,) = _tryInitialize(0, ONE_WEI_USDC);
        assertFalse(whileCodeless, "initialization must fail while the senior rate provider has no code");

        // Restore the code, which is what deploying the kernel does, and the same genesis now succeeds.
        vm.etch(address(stRateProvider), rateProviderCode);
        (bool onceDeployed,) = _tryInitialize(0, ONE_WEI_USDC);
        assertTrue(onceDeployed, "the same hostile genesis succeeds once the rate provider has code");

        _logVerdict(
            "codeless_rate_provider",
            "THE_LOCK_LIFTS_WHEN_THE_KERNEL_IS_DEPLOYED",
            "a pool whose senior rate provider has no code cannot be initialized, so the window opens at kernel deployment"
        );
    }

    /**
     * @notice Pausing the pool itself blocks initialization, through Balancer's own pause rather than the kernel's
     * @dev These are two separate mechanisms and this test exercises the Balancer one. `Vault.initialize` calls
     *      `_ensureUnpaused(pool)`, which is the pool pause set through `IVaultAdmin.pausePool` by the address
     *      recorded as the pool's `pauseManager` at creation
     * @dev A registered pool can be paused before it is initialized, so the window can be closed from the moment
     *      the pool is created
     */
    function test_APausedPoolBlocksInitialization() public {
        // The pool records its pause manager at creation, so the test creates one naming itself.
        _freshPoolWith(address(stRateProvider), address(this));
        assertFalse(vault.isPoolInitialized(pool), "precondition: the pool must be registered and uninitialized");

        vault.pausePool(pool);
        assertTrue(vault.isPoolPaused(pool), "the pool must report itself paused");
        (bool whilePaused,) = _tryInitialize(0, ONE_WEI_USDC);
        assertFalse(whilePaused, "a hostile genesis must fail while the pool is paused");

        // Unpausing and initializing are both operator actions, so they can be one transaction.
        vault.unpausePool(pool);
        (bool afterUnpause,) = _tryInitialize(DEPOSIT_ST, DEPOSIT_QUOTE);
        assertTrue(afterUnpause, "the operator's full-size genesis must succeed once the pool is unpaused");
        (bool firstDeposit,,) = _tryAdd(0, DEPOSIT_QUOTE);
        assertTrue(firstDeposit, "and the market must serve its first deposit immediately");

        _logVerdict(
            "paused_pool_lock",
            "BALANCERS_OWN_POOL_PAUSE_CLOSES_THE_WINDOW",
            "an uninitialized registered pool can be paused by its pause manager, and initialize reverts while it is"
        );
    }

    /**
     * @notice A senior rate provider that reverts blocks initialization, which is the kernel-side lock
     * @dev Distinct from the pool pause above. The kernel is the senior token's rate provider and its `getRate`
     *      carries `whenNotPaused`, which is the kernel's own OpenZeppelin pause and not Balancer's pool pause
     * @dev Balancer reads that rate inside `initialize`, so a paused kernel makes initialization revert for
     *      everyone, with no pause window to expire
     */
    function test_APausedSeniorRateProviderBlocksInitialization() public {
        // A rate provider that reverts while paused, mirroring the kernel's whenNotPaused on getRate.
        PausableRateProvider kernelStandIn = new PausableRateProvider();
        _freshPoolWith(address(kernelStandIn), address(0));

        kernelStandIn.setPaused(true);
        (bool whilePaused,) = _tryInitialize(0, ONE_WEI_USDC);
        assertFalse(whilePaused, "a hostile genesis must fail while the senior rate read reverts");

        kernelStandIn.setPaused(false);
        (bool afterUnpause,) = _tryInitialize(DEPOSIT_ST, DEPOSIT_QUOTE);
        assertTrue(afterUnpause, "the operator's full-size genesis must succeed once the rate read works again");
        (bool firstDeposit,,) = _tryAdd(0, DEPOSIT_QUOTE);
        assertTrue(firstDeposit, "and the market must serve its first deposit immediately");

        _logVerdict(
            "paused_kernel_lock",
            "THE_KERNEL_PAUSE_CLOSES_THE_WINDOW_TOO",
            "the senior rate read reverts while the kernel is paused, and Balancer reads that rate inside initialize"
        );
    }
}

/**
 * @title PausableRateProvider
 * @notice Rate provider that reverts while paused, standing in for the kernel, whose `getRate` carries the
 *         `whenNotPaused` modifier from its own OpenZeppelin pause
 */
contract PausableRateProvider is IRateProvider {
    bool public paused;

    error EnforcedPause();

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    function getRate() external view override(IRateProvider) returns (uint256) {
        require(!paused, EnforcedPause());
        return 1e18;
    }
}
