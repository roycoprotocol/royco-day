// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ZERO_NAV_UNITS } from "./Constants.sol";
import { SyncedAccountingState } from "./Types.sol";
import { Math, NAV_UNIT, UnitsMathLib, toNAVUnits, toUint256 } from "./Units.sol";

/**
 * @title RoycoDayKernelMathLib
 * @notice Stateless, pure share-accounting math shared by the kernel (execution) and the kernel lens (preview),
 *         so the two paths compute identical results (the "preview == execution" invariant) from one source.
 * @dev Only genuinely-pure helpers live here. Helpers that read the kernel's storage or call its venue/quoter
 *      conversions stay on the kernel and the lens.
 */
library RoycoDayKernelMathLib {
    using UnitsMathLib for uint256;

    /**
     * @notice Converts a NAV value to a tranche share count, mirroring `RoycoVaultTranche._convertToShares`.
     * @param _nav The NAV value being converted to shares
     * @param _totalTrancheNAV The tranche's total controlled NAV (the per-share denominator)
     * @param _totalSupply The tranche's total share supply (including any minted protocol fee shares)
     * @return shares The share count for the specified NAV value, rounded down
     */
    function navToShares(NAV_UNIT _nav, NAV_UNIT _totalTrancheNAV, uint256 _totalSupply) internal pure returns (uint256 shares) {
        // With no shares outstanding the conversion is 1:1 with the NAV value, mirroring the tranche's first mint
        if (_totalSupply == 0) return toUint256(_nav);
        // When the total tranche NAV is zero, assume the existing supply is backed by a single NAV unit, mirroring the tranche's boundary
        shares = _totalSupply.mulDiv(_nav, (_totalTrancheNAV == ZERO_NAV_UNITS ? toNAVUnits(uint256(1)) : _totalTrancheNAV), Math.Rounding.Floor);
    }

    /**
     * @notice Computes the senior tranche shares minted for this sync's senior yield split: the LT liquidity premium and the ST protocol fee.
     * @dev Both the premium and the fee are reallocations of value already booked into the senior effective NAV (no assets enter or
     *      leave), so minting them is NAV-neutral and coverage-neutral. Both are priced over the same pre-sync supply against one shared
     *      denominator (stEffectiveNAV - premium - fee) so neither dilutes the other; both round down.
     * @param _state The synced accounting state carrying the senior effective NAV, the liquidity premium, and the ST protocol fee
     * @param _stTotalSupply The total senior tranche share supply before this sync mints the premium and fee shares
     * @return liquidityPremiumShares The senior shares to mint as the LT liquidity premium, rounded down
     * @return stProtocolFeeShares The senior shares to mint as the ST protocol fee, rounded down
     * @return stTotalSupplyAfterMints The total senior tranche supply after minting the premium and fee shares
     */
    function computeSTFeeAndLiquidityPremiumSharesToMint(
        SyncedAccountingState memory _state,
        uint256 _stTotalSupply
    )
        internal
        pure
        returns (uint256 liquidityPremiumShares, uint256 stProtocolFeeShares, uint256 stTotalSupplyAfterMints)
    {
        // The pre-existing senior shares retain the senior effective NAV net of the premium and fee
        // NOTE: The waterfall enforces that (premium + fee) <= senior effective NAV, so the subtraction never underflows
        NAV_UNIT retainedSeniorNAV = (_state.stEffectiveNAV - _state.ltLiquidityPremium - _state.stProtocolFee);

        // Convert each carve-out into senior shares against the retained NAV over the pre-sync supply (the zero-NAV boundary is handled in navToShares)
        liquidityPremiumShares = navToShares(_state.ltLiquidityPremium, retainedSeniorNAV, _stTotalSupply);
        stProtocolFeeShares = navToShares(_state.stProtocolFee, retainedSeniorNAV, _stTotalSupply);
        stTotalSupplyAfterMints = _stTotalSupply + liquidityPremiumShares + stProtocolFeeShares;
    }
}
