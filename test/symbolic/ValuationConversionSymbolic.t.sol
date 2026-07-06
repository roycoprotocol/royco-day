// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

import { toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { ValuationLogic } from "../../src/libraries/logic/ValuationLogic.sol";

/**
 * @title ValuationConversionSymbolic
 * @notice Halmos symbolic specs for the single share/value conversion pair every tranche and the kernel-side mint
 *         sizing share. The load-bearing properties: a floor round-trip in either direction can never create value
 *         or shares out of rounding, the round-trip loss is bounded by one unit of the opposing quantity plus one
 *         wei, the empty-supply edges are exact, and both conversions are total on the bounded domain
 * @dev Run with `halmos --contract ValuationConversionSymbolicSpec`. Functions prefixed check_ are halmos
 *      properties and are not discovered by forge test. Domain: NAVs and share supplies up to 1e30 wei, the
 *      suite-wide bound
 */
contract ValuationConversionSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev Suite-wide share-supply domain bound: 1e30 share wei
    uint256 internal constant MAX_SHARES = 1e30;

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
     */
    function check_valueToSharesAndBackNeverCreatesValueAndLossIsBounded(uint256 value, uint256 totalValue, uint256 totalSupply) external pure {
        // Live tranche: at least one share outstanding backed by at least one NAV wei
        vm.assume(value <= MAX_NAV);
        vm.assume(1 <= totalValue && totalValue <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);

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
     *         total value or rounding mode, so a fresh tranche has no rounding surface at genesis
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
     * @notice When live shares are backed by zero value, the mint prices the whole supply at one NAV wei: a new
     *         deposit mints totalSupply shares per NAV wei, diluting the unbacked holders instead of reverting on
     *         a zero denominator
     */
    function check_zeroTotalValueMintsAgainstAOneWeiDenominator(uint256 value, uint256 totalSupply) external pure {
        vm.assume(value <= MAX_NAV);
        vm.assume(1 <= totalSupply && totalSupply <= MAX_SHARES);

        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(value), toNAVUnits(uint256(0)), totalSupply, Math.Rounding.Floor);
        // mulDiv(totalSupply, value, 1) == totalSupply * value, the one-wei-denominator dilution
        assert(shares == totalSupply * value);
    }

    /*//////////////////////////////////////////////////////////////////////
                            TOTALITY
    //////////////////////////////////////////////////////////////////////*/

    /// @notice The share conversion never reverts anywhere on the bounded domain, in either rounding mode,
    ///         including the zero-supply and zero-value edges, so no tranche state can brick a deposit preview
    function check_convertToSharesNeverRevertsOnBoundedInputs(uint256 value, uint256 totalValue, uint256 totalSupply, bool roundUp) external view {
        vm.assume(value <= MAX_NAV && totalValue <= MAX_NAV && totalSupply <= MAX_SHARES);

        try this.convertToSharesWrapped(value, totalValue, totalSupply, roundUp) returns (uint256) { }
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
