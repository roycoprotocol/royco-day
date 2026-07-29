// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { BasePoolMath } from "../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BasePoolMath.sol";
import { C4BatteryBase } from "./Test_C4FullBattery.t.sol";

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

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// Creates a fresh uninitialized C4 pool, points `pool` at it, and approves the router for its BPT.
    function _freshPool() internal returns (address p) {
        p = _createPool(_eclpParamsC4(), _derivedParamsC4(), false, bytes32(uint256(4000 + saltCounter++)));
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
}
