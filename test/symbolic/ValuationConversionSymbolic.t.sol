// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { MINT_DILUTION_RESIDUAL_WAD, WAD } from "../../src/libraries/Constants.sol";
import { LTEffectiveNAVDriver } from "../mocks/LTEffectiveNAVDriver.sol";
import { ValuationConversionExposer } from "../mocks/ValuationConversionExposer.sol";

/**
 * @title ValuationConversionSymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the single share/value conversion pair every
 *         tranche and the kernel-side mint sizing share, plus the liquidity tranche effective NAV. The
 *         load-bearing properties: a bootstrap mint is one-to-one, the fair (unclamped) branch is exact
 *         floor and ceil pro-rata division, the mint-dilution clamp (residual ε = MINT_DILUTION_RESIDUAL_WAD)
 *         plateaus at exactly the cap S·(WAD − ε)/ε on both rounding modes and never lets a mint own more
 *         than (1 − ε/WAD) of the post-mint supply, the value conversion is exact floor and ceil division and
 *         zero against an empty supply, the two floor round trips can only lose to rounding by at most one
 *         opposing unit, and the liquidity tranche effective NAV is its raw pool depth plus the floored claim
 *         of its idle premium senior shares (reducing to raw when there are none)
 * @dev Functions prefixed check_ are discovered only under --symbolic. Domain: NAVs and share supplies up to
 *      1e30 wei (one trillion whole 18-decimal tokens, beyond any underwritable market); the clamp-totality
 *      check extends the supply to 2^128 deliberately. Every expected value is derived independently: fair
 *      shares as plain integer division `(S*v)/d` and its add-before-divide ceil `(S*v + d - 1)/d`, and the
 *      clamp cap as the PLAIN multiply `S · (1e12 − 1)`. That cap is exact because ε = 1e6 divides WAD = 1e18
 *      with WAD/ε = 1e12, so (WAD − ε)/ε = 1e12 − 1 exactly and the floor in `floor(S·(WAD − ε)/ε)` never
 *      loses a wei. No spec-side expectation re-runs the production OZ mulDiv path
 * @dev Every conversion runs through a separately deployed exposer, and each division-shaped expectation
 *      carries a bounded add-then-subtract padding input, so the queries reach the real SMT solver rather than
 *      the engine's built-in arithmetic heuristic (the same tractability shape the attribution and
 *      tranche-claims specs use). All products on the spec side cap near 1e60 (far below 2^256) so plain
 *      checked arithmetic is exact
 * @dev Migration note on the shares-to-value round trip: its earlier form allowed `shares > totalSupply`, an
 *      unreachable redemption state, and produced a genuine counterexample that was a spec-domain error, not a
 *      source bug. It is now scoped to the redemption domain `shares <= totalSupply`, and the excluded
 *      oversized region is pinned as its own bind-plateau property, so no coverage is lost
 */
contract ValuationConversionSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev Suite-wide share-supply domain bound: 1e30 share wei
    uint256 internal constant MAX_SHARES = 1e30;

    /// @dev A tightened domain for the chained-division round trip and the monotonicity check, where the
    ///      double mulDiv makes the full 1e30 domain stall the solver
    uint256 internal constant TIGHT = 1e24;

    /// @dev The protocol mint-dilution residual, locally aliased for readability
    uint256 internal constant EPS = MINT_DILUTION_RESIDUAL_WAD;

    /// @dev The exact per-share cap multiplier: (WAD − ε)/ε == 1e12 − 1 exactly because ε (1e6) divides WAD
    ///      (1e18), so the clamp cap S·(WAD − ε)/ε is the plain multiply S·(1e12 − 1) with no floor loss
    uint256 internal constant CAP_PER_SHARE = 1e12 - 1;

    ValuationConversionExposer internal exposer;
    LTEffectiveNAVDriver internal ltDriver;

    function setUp() public {
        exposer = new ValuationConversionExposer();
        ltDriver = new LTEffectiveNAVDriver();
    }

    /*//////////////////////////////////////////////////////////////////////
                    BOOTSTRAP AND FAIR-PRICED SHARE CONVERSION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice With no shares outstanding the first mint is exactly one share wei per NAV wei regardless of the
     *         total value or rounding mode — the bootstrap is exempt from the dilution clamp (it dilutes
     *         nobody), so a fresh tranche has no rounding surface and no clamp surface at genesis
     */
    function check_firstMintIsExactlyOneToOneWithValue(uint256 value, uint256 totalValue, bool roundUp) external view {
        vm.assume(value <= MAX_NAV && totalValue <= MAX_NAV);

        uint256 shares = exposer.convertToShares(value, totalValue, 0, roundUp);
        // The bootstrap mint prices one share per NAV wei, seeding the share-per-value ratio at unity
        assert(shares == value);
    }

    /**
     * @notice Below the dilution bind the floor conversion is EXACTLY the plain floored pro-rata slice
     *         (S·v)/d: fair pricing is untouched wherever the residual guarantee is not at stake, so a normal
     *         deposit mints its honest share of the tranche and no more
     * @dev The expected form is an independently written plain integer division, never the production mulDiv:
     *      the numerator S·v caps near 1e60 and the checked multiply is exact. The zero-value case prices the
     *      whole supply against a one-wei denominator (d), matching the source's ZERO_NAV_UNITS substitution
     */
    function check_clampNoBindFloorMintIsExactlyProRata(uint256 value, uint256 totalValue, uint256 totalSupply, uint256 p1) external view {
        vm.assume(value <= MAX_NAV && totalValue <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);
        vm.assume(p1 <= 3);
        // The one-wei denominator the source substitutes when the tranche is worth nothing
        uint256 d = totalValue == 0 ? 1 : totalValue;
        // Pin the no-bind branch in overflow-safe product form: fair shares fit under the residual cap
        vm.assume(value * EPS <= d * (WAD - EPS));

        uint256 shares = exposer.convertToShares(value, totalValue, totalSupply, false);
        // Exact floored pro-rata: the depositor gets floor(S·v/d) shares, dust accreting to existing holders
        assert(shares == (totalSupply * value) / d + p1 - p1);
    }

    /**
     * @notice Below the dilution bind the ceil conversion is EXACTLY the add-before-divide pro-rata slice
     *         (S·v + d − 1)/d: the kernel-side mint sizing that must not under-credit rounds up, and it does so
     *         by exactly one integer division with the standard ceil offset
     * @dev Independent ceil form (add denominator-minus-one before dividing), never the production mulDiv;
     *      S·v + d − 1 caps near 1e60 so the checked add and multiply are exact
     */
    function check_clampNoBindCeilMintIsAddBeforeDivideProRata(uint256 value, uint256 totalValue, uint256 totalSupply, uint256 p1) external view {
        vm.assume(value <= MAX_NAV && totalValue <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);
        vm.assume(p1 <= 3);
        uint256 d = totalValue == 0 ? 1 : totalValue;
        // Same no-bind pin: the fair ceil share count still fits under the residual cap
        vm.assume(value * EPS <= d * (WAD - EPS));

        uint256 shares = exposer.convertToShares(value, totalValue, totalSupply, true);
        // Exact ceiling pro-rata: ceil(S·v/d) written as the add-before-divide form
        assert(shares == (totalSupply * value + d - 1) / d + p1 - p1);
    }

    /**
     * @notice Below the bind the ceil mint never exceeds the floor mint by more than one share wei: the two
     *         rounding modes agree everywhere the division is exact and differ by exactly one share only when
     *         it is not, so a caller can never be over-credited by choosing ceil beyond the coarseness of a
     *         single share
     * @dev Stated purely on the two production outputs (a floor and a ceil mint of the same inputs), with no
     *      spec-side arithmetic beyond the +1 bracket — the defining floor/ceil relationship
     */
    function check_ceilMintNeverExceedsFloorMintByMoreThanOneShareWei(uint256 value, uint256 totalValue, uint256 totalSupply, uint256 p1) external view {
        vm.assume(value <= MAX_NAV && totalValue <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);
        vm.assume(p1 <= 3);
        uint256 d = totalValue == 0 ? 1 : totalValue;
        // No-bind so both rounding modes stay on the fair-pricing branch (the bind branch ignores rounding)
        vm.assume(value * EPS <= d * (WAD - EPS));

        uint256 floorShares = exposer.convertToShares(value, totalValue, totalSupply, false);
        uint256 ceilShares = exposer.convertToShares(value, totalValue, totalSupply, true) + p1 - p1;
        // Ceil is never below floor, and rounds up by at most one share wei
        assert(floorShares <= ceilShares);
        assert(ceilShares <= floorShares + 1);
    }

    /**
     * @notice For a fixed supply and total value, a larger deposit never mints fewer shares below the bind:
     *         the floor conversion is monotone non-decreasing in deposit value, so a depositor can never get
     *         more shares by putting in less, which would invert the tranche's pro-rata economics
     * @dev Both deposits are pinned to the no-bind fair branch so the output is floor(S·v/d) with a fixed
     *      denominator and ordered numerators; flooring preserves the non-strict order. Domain tightened to
     *      1e24 because the paired division makes the full 1e30 domain stall; the tightening only removes
     *      astronomically-large deposits and leaves the ordering claim general. If this stays incomplete the
     *      empirical monotonicity is owned by the deposit-preview fuzz suite
     */
    function check_floorMintIsMonotoneInDepositValue(uint256 valueA, uint256 valueB, uint256 totalValue, uint256 totalSupply, uint256 p1) external view {
        vm.assume(valueA <= valueB && valueB <= TIGHT);
        vm.assume(1 <= totalValue && totalValue <= TIGHT);
        vm.assume(1 <= totalSupply && totalSupply <= TIGHT);
        vm.assume(p1 <= 3);
        // Pin both deposits to the fair branch: the larger one still fits under the residual cap, so the
        // smaller one does too (its numerator is no larger)
        vm.assume(valueB * EPS <= totalValue * (WAD - EPS));

        uint256 sharesA = exposer.convertToShares(valueA, totalValue, totalSupply, false) + p1 - p1;
        uint256 sharesB = exposer.convertToShares(valueB, totalValue, totalSupply, false);
        // A larger deposit into the same tranche always mints at least as many shares
        assert(sharesA <= sharesB);
    }

    /*//////////////////////////////////////////////////////////////////////
                            THE MINT-DILUTION CLAMP
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Above the bind the clamp returns EXACTLY the cap S·(1e12 − 1) on BOTH rounding modes: the mint
     *         plateaus at the residual guarantee (pre-existing holders keep at least ε/WAD of the post-mint
     *         supply) and does not degrade further, and the cap is applied before the rounding dispatch so it
     *         is protective in both directions — a ceil caller cannot round past the plateau
     * @dev The cap is the PLAIN multiply S·(1e12 − 1), not the production mulDiv: exact because ε divides WAD.
     *      The bind is pinned in its integer-equivalent product form value·ε > d·(WAD − ε) (the source's
     *      ceil-division bind test is exactly this inequality)
     */
    function check_clampBindReturnsExactCapRegardlessOfRounding(
        uint256 value,
        uint256 totalValue,
        uint256 totalSupply,
        bool roundUp,
        uint256 p1
    )
        external
        view
    {
        vm.assume(value <= MAX_NAV && totalValue <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);
        vm.assume(p1 <= 3);
        uint256 d = totalValue == 0 ? 1 : totalValue;
        // Pin the bind branch: fair shares would exceed the cap
        vm.assume(value * EPS > d * (WAD - EPS));

        uint256 shares = exposer.convertToShares(value, totalValue, totalSupply, roundUp);
        // The plateau is the exact per-share cap times the supply, independent of the requested rounding
        assert(shares == totalSupply * CAP_PER_SHARE + p1 - p1);
    }

    /**
     * @notice The clamp's defining guarantee on EVERY non-bootstrap branch and BOTH rounding modes: a single
     *         mint owns at most (1 − ε/WAD) of the post-mint supply, equivalently m·ε <= S·(WAD − ε), so
     *         pre-existing holders always retain at least the residual and no mint can dilute them past it
     * @dev Product-form ownership bound with no spec-side division. On the bind branch equality holds exactly
     *      (cap·ε == S·(WAD − ε) since ε divides WAD); on the fair branch the no-bind condition v·ε <= d·(WAD − ε)
     *      forces the fair share count under the cap in both roundings, so the bound is slack there
     */
    function check_clampOwnershipBoundHoldsInBothRoundings(
        uint256 value,
        uint256 totalValue,
        uint256 totalSupply,
        bool roundUp,
        uint256 p1
    )
        external
        view
    {
        vm.assume(value <= MAX_NAV && totalValue <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);
        vm.assume(p1 <= 3);

        uint256 shares = exposer.convertToShares(value, totalValue, totalSupply, roundUp) + p1 - p1;
        // m <= cap  ⟺  m·ε <= S·(WAD − ε); both products fit (m <= cap < 1e43, so m·ε < 1e49)
        assert(shares * EPS <= totalSupply * (WAD - EPS));
    }

    /**
     * @notice When live shares are backed by zero value, the mint prices the whole supply at one NAV wei and
     *         the dilution clamp bounds the capture: below the bind (value·ε <= WAD − ε, i.e. value < ~1e12)
     *         the deposit mints S·value shares exactly, and above it the mint plateaus at the cap S·(1e12 − 1),
     *         so the unbacked holders are diluted to the residual and no further instead of the pre-clamp
     *         unbounded S·value mint
     * @dev The one-wei denominator makes the fair mint the plain product S·value; the cap is the plain
     *      multiply S·(1e12 − 1). Neither expected form re-runs the production mulDiv
     */
    function check_zeroTotalValueMintsAgainstAOneWeiDenominatorUpToTheCap(uint256 value, uint256 totalSupply, uint256 p1) external view {
        vm.assume(value <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);
        vm.assume(p1 <= 3);

        uint256 shares = exposer.convertToShares(value, 0, totalSupply, false);
        if (value * EPS <= (WAD - EPS)) {
            // Below the bind against the one-wei denominator: S·value exactly
            assert(shares == totalSupply * value + p1 - p1);
        } else {
            // Above the bind: the residual plateau, the plain per-share cap times the supply
            assert(shares == totalSupply * CAP_PER_SHARE + p1 - p1);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                            VALUE CONVERSION
    //////////////////////////////////////////////////////////////////////*/

    /// @notice With no shares outstanding a share count has no claim, so its value is exactly zero in both
    ///         rounding modes and a burned-out tranche can never report phantom value
    function check_valueOfSharesAgainstEmptySupplyIsZero(uint256 shares, uint256 totalValue, bool roundUp) external view {
        vm.assume(shares <= MAX_SHARES && totalValue <= MAX_NAV);

        uint256 value = exposer.convertToValue(shares, 0, totalValue, roundUp);
        // An empty supply has nothing to have a claim on
        assert(value == 0);
    }

    /**
     * @notice The floor value conversion is EXACTLY the plain floored division (T·s)/S: a share count is worth
     *         its honest floored slice of the tranche value, rounding against the redeemer so the tranche never
     *         over-pays a withdrawal
     * @dev Independently written plain integer division, never the production mulDiv; T·s caps near 1e60
     */
    function check_convertToValueFloorIsExactPlainDivision(uint256 shares, uint256 totalValue, uint256 totalSupply, uint256 p1) external view {
        vm.assume(shares <= MAX_SHARES && totalValue <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);
        vm.assume(p1 <= 3);

        uint256 value = exposer.convertToValue(shares, totalSupply, totalValue, false);
        // Exact floored slice: floor(T·s/S)
        assert(value == (totalValue * shares) / totalSupply + p1 - p1);
    }

    /**
     * @notice The ceil value conversion is EXACTLY the add-before-divide division (T·s + S − 1)/S: the rate
     *         writer that must not under-report a claim rounds up by exactly one division with the standard
     *         ceil offset, completing the primitive's floor/ceil contract
     * @dev Independent ceil form, never the production mulDiv; T·s + S − 1 caps near 1e60
     */
    function check_convertToValueCeilIsAddBeforeDivide(uint256 shares, uint256 totalValue, uint256 totalSupply, uint256 p1) external view {
        vm.assume(shares <= MAX_SHARES && totalValue <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);
        vm.assume(p1 <= 3);

        uint256 value = exposer.convertToValue(shares, totalSupply, totalValue, true);
        // Exact ceiling slice: ceil(T·s/S) as the add-before-divide form
        assert(value == (totalValue * shares + totalSupply - 1) / totalSupply + p1 - p1);
    }

    /*//////////////////////////////////////////////////////////////////////
                            ROUND-TRIP BOUNDS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Depositing a value, then valuing the minted shares, never returns more than went in: the floor
     *         round trip cannot create value, and it loses at most one share's worth of value plus one wei of
     *         flooring, so a depositor's rounding loss is bounded by the coarseness of a single share
     * @dev Fair pricing only exists below the mint-dilution bind, so the no-bind region is assumed with its
     *      justification: a binding mint deliberately returns less (that is the clamp's purpose, its loss
     *      bounded by the ownership/cap checks above), and the excluded corner is exactly a tranche worth under
     *      ~1e-12 of the deposit. The loss bound is stated in product form: either exact, or the loss L
     *      satisfies (L − 1)·S <= T, since two floors together lose strictly less than T/S + 1. Domain
     *      tightened to 1e24 because the paired division stalls the solver on the full 1e30 domain; if it stays
     *      incomplete the empirical round trip is owned by the tranche deposit/redeem fuzz suite
     */
    function check_valueToSharesAndBackNeverCreatesValueAndLossIsBounded(uint256 value, uint256 totalValue, uint256 totalSupply, uint256 p1) external view {
        vm.assume(value <= TIGHT);
        vm.assume(1 <= totalValue && totalValue <= TIGHT);
        vm.assume(1 <= totalSupply && totalSupply <= TIGHT);
        vm.assume(p1 <= 3);
        // No-bind precondition in overflow-safe product form
        vm.assume(value * EPS <= totalValue * (WAD - EPS));

        uint256 shares = exposer.convertToShares(value, totalValue, totalSupply, false);
        uint256 valueBack = exposer.convertToValue(shares, totalSupply, totalValue, false);

        // The round trip can only lose to flooring, never gain
        assert(valueBack <= value);
        // Product-form loss bound: each of the two floors loses strictly less than one unit of its result
        // scale, telescoping to less than one share's value (T/S) plus one wei, i.e. (L − 1)·S <= T
        uint256 loss = value - valueBack;
        assert(loss == 0 || (loss - 1) * totalSupply <= totalValue + p1 - p1);
    }

    /**
     * @notice Valuing a redeemable share count, then converting the value back to shares, never returns more
     *         shares than went in: the floor round trip cannot mint shares, and it loses at most one NAV wei's
     *         worth of shares, so a redeemer's rounding loss is bounded by the coarseness of a single NAV wei
     * @dev Scoped to the redemption domain shares <= totalSupply — the only reachable case, since a holder can
     *      never redeem more shares than exist. On that domain value = floor(T·s/S) <= T, so value·ε <= T·ε
     *      <= T·(WAD − ε): the return conversion provably stays on the fair branch and never binds the clamp.
     *      (The earlier unscoped form allowed shares > totalSupply, where the return leg binds and the naive
     *      bound fails — a spec-domain error, not a source bug; that region is pinned as its own property
     *      below.) Loss bound in product form (L − 1)·T <= S. Domain tightened to 1e24 as with the mirror
     *      round trip; incomplete-fallback owner is the tranche redeem fuzz suite
     */
    function check_redeemableSharesToValueAndBackNeverMintsSharesAndLossIsBounded(
        uint256 shares,
        uint256 totalValue,
        uint256 totalSupply,
        uint256 p1
    )
        external
        view
    {
        vm.assume(1 <= totalValue && totalValue <= TIGHT);
        vm.assume(1 <= totalSupply && totalSupply <= TIGHT);
        vm.assume(p1 <= 3);
        // The redemption domain: a holder can only ever redeem shares that exist
        vm.assume(shares <= totalSupply);

        uint256 value = exposer.convertToValue(shares, totalSupply, totalValue, false);
        uint256 sharesBack = exposer.convertToShares(value, totalValue, totalSupply, false);

        // The round trip can only lose to flooring, never gain
        assert(sharesBack <= shares);
        // Product-form loss bound mirroring the value-first round trip: at most one NAV wei's share count
        uint256 loss = shares - sharesBack;
        assert(loss == 0 || (loss - 1) * totalValue <= totalSupply + p1 - p1);
    }

    /**
     * @notice The excluded region of the redemption round trip, as its own property: an oversized share count
     *         whose value binds the return-leg clamp is repriced to exactly the cap S·(1e12 − 1), strictly
     *         below the oversized count, so the round trip still never mints shares even outside the redemption
     *         domain — the clamp is exactly what keeps the no-creation guarantee total
     * @dev Partitions the live-tranche domain with the fixed redemption round trip above. The bind is pinned
     *      on the intermediate value in its integer-equivalent product form value·ε > T·(WAD − ε). Independent
     *      derivation that the cap is below the input: the bind gives value·ε > T·(WAD − ε), and value <= T·s/S,
     *      so T·s·ε/S > T·(WAD − ε), i.e. s > S·(WAD − ε)/ε == S·(1e12 − 1) == the cap
     */
    function check_oversizedShareCountBindsReturnLegClampAtCapAndNeverMintsShares(
        uint256 shares,
        uint256 totalValue,
        uint256 totalSupply,
        uint256 p1
    )
        external
        view
    {
        vm.assume(shares <= MAX_SHARES);
        vm.assume(1 <= totalValue && totalValue <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);
        vm.assume(p1 <= 3);

        uint256 value = exposer.convertToValue(shares, totalSupply, totalValue, false);
        // Pin the return leg onto the bind branch (denominator is totalValue since it is positive)
        vm.assume(value * EPS > totalValue * (WAD - EPS));

        uint256 sharesBack = exposer.convertToShares(value, totalValue, totalSupply, false);
        // Repriced to exactly the residual plateau, which the bind forces strictly below the oversized input
        assert(sharesBack == totalSupply * CAP_PER_SHARE + p1 - p1);
        assert(sharesBack < shares);
    }

    /*//////////////////////////////////////////////////////////////////////
                            TOTALITY
    //////////////////////////////////////////////////////////////////////*/

    /// @notice The share conversion never reverts anywhere on the bounded domain, in either rounding mode,
    ///         including the zero-supply and zero-value edges, so no tranche state on the suite domain can
    ///         brick a deposit preview
    function check_convertToSharesNeverRevertsOnBoundedInputs(uint256 value, uint256 totalValue, uint256 totalSupply, bool roundUp) external view {
        vm.assume(value <= MAX_NAV && totalValue <= MAX_NAV && totalSupply <= MAX_SHARES);

        try exposer.convertToShares(value, totalValue, totalSupply, roundUp) returns (uint256) { }
        catch {
            assert(false);
        }
    }

    /**
     * @notice The bind-first ordering's no-panic property on the EXTENDED domain the pre-clamp code could not
     *         survive: the conversion is total for any supply up to 2^128 with UNBOUNDED value and totalValue,
     *         including the huge-value-over-dust-denominator states where computing fair shares first would
     *         overflow. Provable: the bind test's intermediate is at most value; a bind returns
     *         cap <= 2^128·(WAD − ε)/ε < 2^256; and a no-bind fair mint is <= cap so its mulDiv reduction fits.
     *         The residual cliff begins only past supply ~2^256·ε/(WAD − ε) ≈ 1.158e65, far above this domain
     *         and pinned separately by test_DIVERGENCE_11_mintDilutionClamp_residualOverflowCliff in
     *         test/concrete/Divergences/Test_SpecDivergences.t.sol
     */
    function check_clampNeverRevertsOnExtendedDomain(uint256 value, uint256 totalValue, uint256 totalSupply) external view {
        vm.assume(totalSupply <= 2 ** 128);

        try exposer.convertToShares(value, totalValue, totalSupply, false) returns (uint256) { }
        catch {
            assert(false);
        }
    }

    /// @notice The value conversion never reverts anywhere on the bounded domain, in either rounding mode,
    ///         including the zero-supply edge, so no tranche state can brick a redemption preview
    function check_convertToValueNeverRevertsOnBoundedInputs(uint256 shares, uint256 totalValue, uint256 totalSupply, bool roundUp) external view {
        vm.assume(shares <= MAX_SHARES && totalValue <= MAX_NAV && totalSupply <= MAX_SHARES);

        try exposer.convertToValue(shares, totalSupply, totalValue, roundUp) returns (uint256) { }
        catch {
            assert(false);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                        LIQUIDITY TRANCHE EFFECTIVE NAV
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The liquidity tranche effective NAV reduces to its raw pool depth exactly when there are no idle
     *         premium senior shares to value, or no senior shares outstanding at all: with nothing staged, the
     *         effective NAV is purely the deployed market-making inventory, so the steady state (all premium
     *         reinvested) prices the LT share on pool depth alone
     * @dev One early-return branch of the source, selected by the disjunction. The raw NAV is pinned through
     *      the driver's identity conversion, so the expected effective NAV is that raw value unchanged
     */
    function check_ltEffectiveNAVReducesToRawWhenNoIdleSharesOrNoSeniorSupply(
        uint256 ltRawNAV,
        uint256 stEffectiveNAV,
        uint256 held,
        uint256 totalST
    )
        external
    {
        vm.assume(ltRawNAV <= MAX_NAV && stEffectiveNAV <= MAX_NAV);
        vm.assume(held <= MAX_SHARES && totalST <= MAX_SHARES);
        // Pin the early-return branch: no idle premium shares to value, or no senior supply to price them
        vm.assume(held == 0 || totalST == 0);

        ltDriver.setLTRawNAV(ltRawNAV);
        uint256 ltEff = ltDriver.ltEffectiveNAV(stEffectiveNAV, totalST, held);
        // With nothing staged, the effective NAV is exactly the raw pool depth
        assert(ltEff == ltRawNAV);
    }

    /**
     * @notice With idle premium senior shares staged and a live senior supply, the liquidity tranche effective
     *         NAV is exactly its raw pool depth plus the floored claim those shares have on the senior
     *         effective NAV — the "pool plus idle claimable leg" valuation. Both overloads (the storage-count
     *         and the explicitly-supplied-count preview path) return the identical value, so the previewed LT
     *         NAV matches what execution computes from storage
     * @dev Independent additive form: ltRaw + floor(stEff·held/totalST), the floor written as plain integer
     *      division (stEff·held caps near 1e60). The held count is within the senior supply, its realistic
     *      range, which also keeps the added claim bounded by stEff
     */
    function check_ltEffectiveNAVIsRawPlusFlooredIdleShareClaim(
        uint256 ltRawNAV,
        uint256 stEffectiveNAV,
        uint256 held,
        uint256 totalST,
        uint256 p1
    )
        external
    {
        vm.assume(ltRawNAV <= MAX_NAV && stEffectiveNAV <= MAX_NAV);
        vm.assume(1 <= totalST && totalST <= MAX_SHARES);
        vm.assume(p1 <= 3);
        // Staged idle premium shares within the senior supply (the reachable range)
        vm.assume(1 <= held && held <= totalST);

        ltDriver.setLTRawNAV(ltRawNAV);
        ltDriver.setLTOwnedSeniorTrancheShares(held);

        uint256 fromStorage = ltDriver.ltEffectiveNAV(stEffectiveNAV, totalST);
        uint256 fromExplicit = ltDriver.ltEffectiveNAV(stEffectiveNAV, totalST, held);

        // Both overloads agree: the preview path reproduces the value execution reads from storage
        assert(fromStorage == fromExplicit);
        // The additive valuation: pool depth plus the floored claim of the idle premium shares
        assert(fromExplicit == ltRawNAV + (stEffectiveNAV * held) / totalST + p1 - p1);
    }
}
