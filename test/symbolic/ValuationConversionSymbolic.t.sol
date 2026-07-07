// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { MINT_DILUTION_RESIDUAL_WAD, WAD } from "../../src/libraries/Constants.sol";
import { toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { ValuationLogic } from "../../src/libraries/logic/ValuationLogic.sol";

/**
 * @title ValuationConversionSymbolic
 * @notice Halmos symbolic specs for the single share/value conversion pair every tranche and the kernel-side mint
 *         sizing share. The load-bearing properties: a floor round-trip in either direction can never create value
 *         or shares out of rounding, the round-trip loss is bounded by one unit of the opposing quantity plus one
 *         wei, the empty-supply edges are exact, both conversions are total on the bounded domain, and the
 *         mint-dilution clamp (ε = MINT_DILUTION_RESIDUAL_WAD) is exactly the three-branch function it claims to
 *         be: identity below the bind, the cap above it, ownership-bounded everywhere
 * @dev Run with `halmos --contract ValuationConversionSymbolicSpec`. Functions prefixed check_ are halmos
 *      properties and are not discovered by forge test. Domain: NAVs and share supplies up to 1e30 wei, the
 *      suite-wide bound (the clamp-totality check extends it deliberately)
 */
contract ValuationConversionSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev Suite-wide share-supply domain bound: 1e30 share wei
    uint256 internal constant MAX_SHARES = 1e30;

    /// @dev The protocol residual, locally aliased for readability
    uint256 internal constant EPS = MINT_DILUTION_RESIDUAL_WAD;

    /*//////////////////////////////////////////////////////////////////////
                            EXTERNAL WRAPPERS
    //////////////////////////////////////////////////////////////////////*/

    /// @dev External wrapper so the totality checks can observe a revert through try/catch
    function convertToSharesWrapped(uint256 _value, uint256 _totalValue, uint256 _totalSupply, bool _roundUp) external pure returns (uint256) {
        return ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _totalSupply, _roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor);
    }

    /// @dev External wrapper so the totality checks can observe a revert through try/catch
    function convertToValueWrapped(uint256 _shares, uint256 _totalSupply, uint256 _totalValue, bool _roundUp) external pure returns (uint256) {
        return toUint256(ValuationLogic._convertToValue(_shares, _totalSupply, toNAVUnits(_totalValue), _roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor));
    }

    /*//////////////////////////////////////////////////////////////////////
                            ROUND-TRIP BOUNDS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Depositing a value, then valuing the minted shares, never returns more than went in: the floor
     *         round-trip cannot create value, and it loses at most one share's worth of value plus one wei of
     *         flooring, so a depositor's rounding loss is bounded by the coarseness of a single share
     * @dev Fair pricing only exists below the mint-dilution bind, so the no-bind region is assumed with its
     *      justification: a binding mint deliberately returns less (the clamp's purpose; its loss bound is the
     *      ownership/cap checks below), and the excluded corner is exactly totalValue < value * ε / (WAD − ε),
     *      i.e. a tranche worth under ~1e-12 of the deposit
     */
    function check_valueToSharesAndBackNeverCreatesValueAndLossIsBounded(uint256 value, uint256 totalValue, uint256 totalSupply) external pure {
        // Live tranche: at least one share outstanding backed by at least one NAV wei
        vm.assume(value <= MAX_NAV);
        vm.assume(1 <= totalValue && totalValue <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);
        // No-bind precondition in overflow-safe product form (both sides <= 1e30 * 1e18)
        vm.assume(value * EPS <= totalValue * (WAD - EPS));

        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(value), toNAVUnits(totalValue), totalSupply, Math.Rounding.Floor);
        uint256 valueBack = toUint256(ValuationLogic._convertToValue(shares, totalSupply, toNAVUnits(totalValue), Math.Rounding.Floor));

        // The round-trip can only lose to flooring, never gain
        assert(valueBack <= value);
        // Each of the two floors loses strictly less than one unit of its result scale, which telescopes to a
        // loss of at most one share's value (totalValue / totalSupply) plus one wei
        assert(value - valueBack <= totalValue / totalSupply + 1);
    }

    /**
     * @notice Valuing a share count, then converting the value back to shares, never returns more shares than went
     *         in: the floor round-trip cannot mint shares, and it loses at most one NAV wei's worth of shares plus
     *         one share wei, so a redeemer's rounding loss is bounded by the coarseness of a single NAV wei
     * @dev No bind conditioning is needed on this direction: value = floor(T * shares / S) <= T, and
     *      value * ε <= T * ε <= T * (WAD − ε), so the reverse conversion is always fair-priced
     */
    function check_sharesToValueAndBackNeverMintsSharesAndLossIsBounded(uint256 shares, uint256 totalValue, uint256 totalSupply) external pure {
        // Live tranche: at least one share outstanding backed by at least one NAV wei
        vm.assume(shares <= MAX_SHARES);
        vm.assume(1 <= totalValue && totalValue <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);

        uint256 value = toUint256(ValuationLogic._convertToValue(shares, totalSupply, toNAVUnits(totalValue), Math.Rounding.Floor));
        uint256 sharesBack = ValuationLogic._convertToShares(toNAVUnits(value), toNAVUnits(totalValue), totalSupply, Math.Rounding.Floor);

        // The round-trip can only lose to flooring, never gain
        assert(sharesBack <= shares);
        // Mirror bound of the value-first round-trip: at most one NAV wei's share count plus one share wei
        assert(shares - sharesBack <= totalSupply / totalValue + 1);
    }

    /*//////////////////////////////////////////////////////////////////////
                    EMPTY-SUPPLY AND EMPTY-VALUE EDGES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice With no shares outstanding the first mint is exactly one share wei per NAV wei regardless of the
     *         total value or rounding mode — the bootstrap is exempt from the dilution clamp (it dilutes
     *         nobody), so a fresh tranche has no rounding surface and no clamp surface at genesis
     */
    function check_firstMintIsExactlyOneToOneWithValue(uint256 value, uint256 totalValue, bool roundUp) external pure {
        vm.assume(value <= MAX_NAV && totalValue <= MAX_NAV);

        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(value), toNAVUnits(totalValue), 0, roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor);
        assert(shares == value);
    }

    /// @notice With no shares outstanding a share count has no claim, so its value is exactly zero in both
    ///         rounding modes and a burned-out tranche can never report phantom value
    function check_valueOfSharesAgainstEmptySupplyIsZero(uint256 shares, uint256 totalValue, bool roundUp) external pure {
        vm.assume(shares <= MAX_SHARES && totalValue <= MAX_NAV);

        uint256 value = toUint256(ValuationLogic._convertToValue(shares, 0, toNAVUnits(totalValue), roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor));
        assert(value == 0);
    }

    /**
     * @notice When live shares are backed by zero value, the mint prices the whole supply at one NAV wei and the
     *         dilution clamp bounds the capture: below the bind (value * ε <= WAD − ε, i.e. value < ~1e12) the
     *         deposit mints totalSupply * value shares exactly; above it the mint plateaus at the cap
     *         floor(totalSupply * (WAD − ε) / ε), so the unbacked holders are diluted to the residual and no
     *         further — instead of the pre-clamp unbounded supply * value mint
     */
    function check_zeroTotalValueMintsAgainstAOneWeiDenominatorUpToTheCap(uint256 value, uint256 totalSupply) external pure {
        vm.assume(value <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);

        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(value), toNAVUnits(uint256(0)), totalSupply, Math.Rounding.Floor);
        if (value * EPS <= (WAD - EPS)) {
            // mulDiv(totalSupply, value, 1) == totalSupply * value, the one-wei-denominator dilution
            assert(shares == totalSupply * value);
        } else {
            assert(shares == Math.mulDiv(totalSupply, WAD - EPS, EPS));
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                        THE MINT-DILUTION CLAMP
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The clamp's defining guarantee: a single mint owns at most (1 − ε/WAD) of the post-mint supply —
     *         equivalently m * ε <= S * (WAD − ε) — so pre-existing holders always retain at least the
     *         residual, on every branch of the conversion (bootstrap exempt by design)
     */
    function check_clampOwnershipBound(uint256 value, uint256 totalValue, uint256 totalSupply) external pure {
        vm.assume(value <= MAX_NAV && totalValue <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);

        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(value), toNAVUnits(totalValue), totalSupply, Math.Rounding.Floor);
        // m <= cap  ⟺  m * ε <= S * (WAD − ε); both products fit: m <= S * (WAD − ε) / ε < 1e43
        assert(shares * EPS <= totalSupply * (WAD - EPS));
    }

    /// @notice Above the bind the clamp returns EXACTLY the cap floor(S * (WAD − ε) / ε) — the mint plateaus
    ///         at the residual guarantee, it does not degrade any further
    function check_clampBindReturnsCap(uint256 value, uint256 totalValue, uint256 totalSupply) external pure {
        vm.assume(value <= MAX_NAV && totalValue <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);
        uint256 d = totalValue == 0 ? 1 : totalValue;
        vm.assume(value * EPS > d * (WAD - EPS)); // the bind, in its integer-equivalent product form

        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(value), toNAVUnits(totalValue), totalSupply, Math.Rounding.Floor);
        assert(shares == Math.mulDiv(totalSupply, WAD - EPS, EPS));
    }

    /// @notice Below the bind the clamp is the identity: the mint equals the unclamped floor formula exactly,
    ///         so fair pricing is untouched everywhere the residual guarantee is not at stake
    function check_clampNoBindIsIdentity(uint256 value, uint256 totalValue, uint256 totalSupply) external pure {
        vm.assume(value <= MAX_NAV && totalValue <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);
        uint256 d = totalValue == 0 ? 1 : totalValue;
        vm.assume(value * EPS <= d * (WAD - EPS)); // at or below the bind

        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(value), toNAVUnits(totalValue), totalSupply, Math.Rounding.Floor);
        assert(shares == Math.mulDiv(totalSupply, value, d));
    }

    /*//////////////////////////////////////////////////////////////////////
                            TOTALITY
    //////////////////////////////////////////////////////////////////////*/

    /// @notice The share conversion never reverts anywhere on the bounded domain, in either rounding mode,
    ///         including the zero-supply and zero-value edges, so no tranche state on the suite domain can
    ///         brick a deposit preview
    function check_convertToSharesNeverRevertsOnBoundedInputs(uint256 value, uint256 totalValue, uint256 totalSupply, bool roundUp) external view {
        vm.assume(value <= MAX_NAV && totalValue <= MAX_NAV && totalSupply <= MAX_SHARES);

        try this.convertToSharesWrapped(value, totalValue, totalSupply, roundUp) returns (uint256) { }
        catch {
            assert(false);
        }
    }

    /**
     * @notice The bind-first ordering's no-panic property on the EXTENDED domain the pre-clamp code could not
     *         survive: the conversion is total for any supply up to 2^128 with UNBOUNDED value and totalValue —
     *         including the huge-value-over-dust-denominator states where computing fair shares first would
     *         overflow. Provable: the bind test's intermediate is at most value; a bind returns
     *         cap <= 2^128 * (WAD − ε) / ε < 2^256; and a no-bind fair mint is <= cap so its mulDiv reduction
     *         fits. (The residual cliff begins only past supply ~2^256 * ε / (WAD − ε) ≈ 1.158e65, far above
     *         this domain — pinned separately by
     *      test_FINDING_11_mintDilutionClamp_residualOverflowCliff in
     *      test/concrete/Findings/Test_SpecDivergences.t.sol.)
     */
    function check_clampNeverRevertsOnExtendedDomain(uint256 value, uint256 totalValue, uint256 totalSupply) external view {
        vm.assume(totalSupply <= 2 ** 128);

        try this.convertToSharesWrapped(value, totalValue, totalSupply, false) returns (uint256) { }
        catch {
            assert(false);
        }
    }

    /// @notice The value conversion never reverts anywhere on the bounded domain, in either rounding mode,
    ///         including the zero-supply edge, so no tranche state can brick a redemption preview
    function check_convertToValueNeverRevertsOnBoundedInputs(uint256 shares, uint256 totalValue, uint256 totalSupply, bool roundUp) external view {
        vm.assume(shares <= MAX_SHARES && totalValue <= MAX_NAV && totalSupply <= MAX_SHARES);

        try this.convertToValueWrapped(shares, totalSupply, totalValue, roundUp) returns (uint256) { }
        catch {
            assert(false);
        }
    }
}
