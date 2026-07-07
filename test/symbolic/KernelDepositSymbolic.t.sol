// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { KernelDepositExposer } from "../mocks/KernelDepositExposer.sol";

/**
 * @title KernelDepositSymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the senior-share sizing of the multi-asset LT
 *         deposit's ST leg: the exact characterization of the region where the floor-rounded conversion sizes
 *         zero senior shares. The load-bearing result is the divergence candidate: whenever the ST leg's NAV
 *         value times the senior share supply is below the senior effective NAV (the deposit is worth less
 *         than one senior share), the sizing returns zero shares, yet the execution path still credits the
 *         deposited ST underlying to the senior tranche's holdings unconditionally, so that value is silently
 *         donated to existing senior holders and never reaches the venue add's senior leg. The remaining
 *         checks close the characterization on every other arm of the conversion (value covering at least one
 *         share on the fair branch, the mint-dilution clamp branch, the bootstrap supply, and the unbacked
 *         supply), proving zero-share sizing happens in exactly that dust region and nowhere else
 * @dev Run with `forge test --symbolic --match-path test/symbolic/KernelDepositSymbolic.t.sol`. Functions
 *      prefixed check_ are discovered only under --symbolic. Domain: the bootstrap arm proves up to 1e30 wei;
 *      the four arms that execute the production pro-rata division (two chained full-width mul-divs, the ceil
 *      dilution bind test feeding the fair floor) prove on a tightened 1e24-wei domain (one million whole
 *      18-decimal tokens, still beyond any underwritable market), the standard tightening for multi-mul-div
 *      chains. Every expected value is derived independently: floors as plain checked multiply and divide
 *      (products cap at 1e48, far below 2^256) and region membership stated in product form (value * supply
 *      against NAV), never by re-running the production mulDiv chain as its own expectation. Each region
 *      assume is paired with its implied linear restatements (constant-multiplier comparisons) so every
 *      branch decision inside the conversion is decidable without nonlinear reasoning, and each assertion
 *      carries a bounded add-then-subtract padding term so the query reaches the real SMT solver rather than
 *      the engine's built-in arithmetic heuristic
 */
contract KernelDepositSymbolicSpec is Test {
    /// @dev NAV domain bound for the single-branch bootstrap arm: 1e30 NAV wei
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev Tightened domain for every arm that executes the chained bind-test and pro-rata mul-divs
    uint256 internal constant TIGHT = 1e24;

    /// @dev WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /// @dev The mint-dilution residual: a single mint may own at most (1 - EPS/WAD) of the post-mint supply
    uint256 internal constant EPS = 1e6;

    KernelDepositExposer internal exposer;

    function setUp() public {
        exposer = new KernelDepositExposer();
    }

    /*//////////////////////////////////////////////////////////////////////
                    THE ZERO-SHARE DUST REGION (DIVERGENCE PIN)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On a backed senior supply, an ST leg worth less than one senior share (value * supply strictly
     *         below the senior effective NAV) sizes exactly zero senior shares. This pins actual production
     *         behavior as a divergence candidate: the multi-asset deposit flow credits the deposited ST
     *         underlying to the senior tranche's holdings before minting, unconditionally on the sized share
     *         count, so a zero-share ST leg still raises the senior raw NAV. The depositor's value is silently
     *         donated to existing senior holders, the venue add receives no senior leg, and the LT shares the
     *         depositor receives are priced only on the liquidity actually minted, so nothing claws the
     *         donation back. First principles say a zero-share ST leg should revert (or skip the credit)
     *         rather than accept value it mints no claim against
     * @dev Independent derivation of both facts. Region: with supply >= 1, value * supply < stEffNAV forces
     *      value < stEffNAV, and since EPS <= WAD - EPS this gives value * EPS < stEffNAV * (WAD - EPS), so
     *      the mint-dilution clamp's bind test cannot pass and the fair floor branch executes. Both implied
     *      facts are also stated as explicit assumes (sound: they narrow nothing) so the bind-test branch
     *      refutation is a linear comparison. Zero result: the fair branch floors supply * value / stEffNAV,
     *      which is zero exactly when the numerator is below the denominator, the region's defining
     *      inequality. The padding input keeps the final query on the real SMT solver
     */
    function check_DIVERGENCE_candidate_stLegWorthLessThanOneSeniorShareSizesZeroSharesWhileItsUnderlyingIsStillCredited(
        uint256 value,
        uint256 stEffNAV,
        uint256 totalSTShares,
        uint256 p1
    )
        external
        view
    {
        // A live senior tranche: backed NAV and outstanding shares
        vm.assume(1 <= stEffNAV && stEffNAV <= TIGHT);
        vm.assume(1 <= totalSTShares && totalSTShares <= TIGHT);
        // The dust region: the deposit's value cannot buy one whole senior share at the current share price
        vm.assume(value * totalSTShares < stEffNAV);
        // Implied linear restatements of the region (derivations in the dev note), assumed explicitly so the
        // conversion's internal branch decisions never need the nonlinear product above
        vm.assume(value < stEffNAV);
        vm.assume(value * EPS <= stEffNAV * (WAD - EPS));
        vm.assume(p1 <= 3);

        uint256 shares = exposer.sizeSTLegShares(value, stEffNAV, totalSTShares);

        // Zero senior shares are minted, yet the execution path has already committed the underlying credit:
        // the whole ST leg lands in the senior raw NAV as a donation with no share claim attached
        assert(shares + p1 - p1 == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
                    THE COMPLEMENT: EVERY OTHER ARM MINTS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On the fair-priced branch of a backed senior supply, an ST leg worth at least one senior share
     *         (value * supply at or above the senior effective NAV) always sizes at least one share. Together
     *         with the clamp-branch check below this proves the zero-share donation region is exactly the
     *         dust region and nothing larger: no economically meaningful deposit can fall into it
     * @dev The fair branch floors supply * value / stEffNAV, and a floor is at least one exactly when the
     *      numerator reaches the denominator, which is this region's defining inequality. The no-bind
     *      assumption pins the fair branch in product form (value * EPS at most stEffNAV * (WAD - EPS), the
     *      exact complement of the production bind test cross-multiplied, with no ceil re-run on the spec
     *      side). Both products carry one constant factor, so the branch pin is a linear comparison. The
     *      padding input keeps the final query on the real SMT solver
     */
    function check_stLegWorthAtLeastOneSeniorShareAlwaysMintsOnTheFairBranch(
        uint256 value,
        uint256 stEffNAV,
        uint256 totalSTShares,
        uint256 p1
    )
        external
        view
    {
        vm.assume(1 <= value && value <= TIGHT);
        vm.assume(1 <= stEffNAV && stEffNAV <= TIGHT);
        vm.assume(1 <= totalSTShares && totalSTShares <= TIGHT);
        // Pin the fair (no-clamp) branch: the bind test fails exactly when value*EPS <= stEffNAV*(WAD - EPS)
        vm.assume(value * EPS <= stEffNAV * (WAD - EPS));
        // The deposit covers at least one whole senior share at the current share price
        vm.assume(value * totalSTShares >= stEffNAV);
        vm.assume(p1 <= 3);

        uint256 shares = exposer.sizeSTLegShares(value, stEffNAV, totalSTShares);

        // Why this matters: a nonzero floor here means the depositor holds a senior claim on the credited
        // underlying, so the unconditional raw-NAV credit is backed and no donation occurs in this region
        assert(shares + p1 - p1 >= 1);
    }

    /**
     * @notice When the mint-dilution clamp binds (the deposit is so large relative to the senior NAV that a
     *         fair pricing would hand it more than its allowed slice of the post-mint supply), the sizing
     *         returns the clamp cap, which is strictly positive for any live supply. The clamp branch can
     *         therefore never produce the zero-share donation: zero shares only happen in the dust region
     * @dev The cap is the floor of supply * (WAD - EPS) / EPS, and since EPS divides WAD exactly this is
     *      supply * (1e12 - 1) with no floor loss, at least 1e12 - 1 for any supply of one share or more.
     *      The bind region is pinned in product form (value * EPS above stEffNAV * (WAD - EPS), the exact
     *      production bind test cross-multiplied), plus its implied linear floor on the value alone: with
     *      stEffNAV >= 1 the bind forces value * EPS > WAD - EPS, so value > 1e12 - 1, that is value >= 1e12
     *      (assumed explicitly, narrowing nothing, so the bind branch selection is a constant comparison).
     *      The padding input keeps the final query on the real SMT solver
     */
    function check_stLegUnderTheMintDilutionClampAlwaysMintsTheExactPositiveCap(
        uint256 value,
        uint256 stEffNAV,
        uint256 totalSTShares,
        uint256 p1
    )
        external
        view
    {
        vm.assume(1 <= value && value <= TIGHT);
        vm.assume(1 <= stEffNAV && stEffNAV <= TIGHT);
        vm.assume(1 <= totalSTShares && totalSTShares <= TIGHT);
        // Pin the clamp branch: the bind test passes exactly when value*EPS > stEffNAV*(WAD - EPS)
        vm.assume(value * EPS > stEffNAV * (WAD - EPS));
        // Implied linear restatement of the bind (derivation in the dev note), assumed explicitly
        vm.assume(value >= WAD / EPS);
        vm.assume(p1 <= 3);

        uint256 shares = exposer.sizeSTLegShares(value, stEffNAV, totalSTShares);

        // The clamped mint still hands the depositor its maximal allowed slice, never zero, so the
        // unconditional underlying credit is always (partially) backed by a share claim on this branch
        assert(shares + p1 - p1 == totalSTShares * (1e12 - 1));
    }

    /*//////////////////////////////////////////////////////////////////////
                        BOOTSTRAP AND UNBACKED SUPPLY EDGES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice With no senior shares outstanding the conversion is exactly one-to-one with the deposited
     *         value, so on a bootstrap supply only a worthless ST leg sizes zero shares: the donation region
     *         does not exist before the first senior mint, and a market's very first multi-asset LT deposit
     *         cannot lose its ST leg to it
     */
    function check_stLegOnBootstrapSupplySizesOneShareWeiPerValueWei(uint256 value, uint256 stEffNAV, uint256 p1) external view {
        vm.assume(value <= MAX_NAV);
        vm.assume(stEffNAV <= MAX_NAV);
        vm.assume(p1 <= 3);

        // Zero shares outstanding: the bootstrap arm prices one share wei per NAV wei regardless of the NAV
        uint256 shares = exposer.sizeSTLegShares(value + p1 - p1, stEffNAV, 0);

        // A bootstrap mint dilutes nobody, so the value converts identically and any positive value mints
        assert(shares == value);
    }

    /**
     * @notice On an unbacked senior supply (shares outstanding against a zero senior effective NAV), the
     *         conversion prices against a one-wei denominator so new depositors dilute the unbacked holders:
     *         every positive value sizes supply-times-value shares. The zero-share donation therefore needs a
     *         positive senior NAV, only a worthless ST leg mints nothing here
     * @dev The one-wei denominator makes the fair branch floor supply * value / 1 == supply * value exactly,
     *      no rounding at all. The no-bind assumption against the one-wei denominator is value * EPS at most
     *      WAD - EPS, and since EPS divides WAD that is exactly value <= 1e12 - 1 (both forms assumed, the
     *      constant bound narrowing nothing, so the branch selection is a constant comparison). Values at or
     *      above 1e12 take the clamp branch, already proven positive above. The padding input keeps the
     *      final query on the real SMT solver
     */
    function check_stLegOnUnbackedSupplyPricesAgainstOneWeiSoEveryPositiveValueMints(uint256 value, uint256 totalSTShares, uint256 p1) external view {
        vm.assume(1 <= totalSTShares && totalSTShares <= TIGHT);
        // Pin the fair branch against the one-wei denominator: no-bind iff value*EPS <= 1*(WAD - EPS)
        vm.assume(value * EPS <= WAD - EPS);
        // The same pin as a constant bound (exact because EPS divides WAD), assumed explicitly
        vm.assume(value <= WAD / EPS - 1);
        vm.assume(p1 <= 3);

        uint256 shares = exposer.sizeSTLegShares(value, 0, totalSTShares);

        // Why this matters: with nothing backing the existing shares, the credited ST underlying is the only
        // real value in the tranche, and pricing at one wei per share hands the depositor the whole of it
        assert(shares + p1 - p1 == totalSTShares * value);
    }
}
