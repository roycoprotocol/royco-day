// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { SyncedAccountingState } from "../../src/libraries/Types.sol";
import { Math, toNAVUnits } from "../../src/libraries/Units.sol";
import { FeeAndLiquidityPremiumLogic } from "../../src/libraries/logic/FeeAndLiquidityPremiumLogic.sol";
import { ValuationLogic } from "../../src/libraries/logic/ValuationLogic.sol";

/**
 * @title CarveOutWrapper
 * @notice Thin external wrapper over the pure senior-share carve-out sizing (the LT liquidity premium and the
 *         ST protocol fee split) and the share-conversion primitive it prices each carve-out with
 * @dev External entrypoints let a test observe reverts anywhere in the sizing math through try/catch
 */
contract CarveOutWrapper {
    /// @notice Sizes the senior shares to mint for the sync's liquidity premium and ST protocol fee carve-outs
    function computeSTFeeAndLiquidityPremiumSharesToMint(
        SyncedAccountingState memory _state,
        uint256 _stTotalSupply
    )
        external
        pure
        returns (uint256 liquidityPremiumShares, uint256 stProtocolFeeShares, uint256 stTotalSupplyAfterMints)
    {
        return FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(_state, _stTotalSupply);
    }

    /// @notice Compact overload over the three NAV legs the carve-out sizing actually reads from the synced state
    function computeSTFeeAndLiquidityPremiumSharesToMint(
        uint256 _stEffectiveNAV,
        uint256 _ltLiquidityPremium,
        uint256 _stProtocolFee,
        uint256 _stTotalSupply
    )
        external
        pure
        returns (uint256 liquidityPremiumShares, uint256 stProtocolFeeShares, uint256 stTotalSupplyAfterMints)
    {
        SyncedAccountingState memory state;
        state.stEffectiveNAV = toNAVUnits(_stEffectiveNAV);
        state.ltLiquidityPremium = toNAVUnits(_ltLiquidityPremium);
        state.stProtocolFee = toNAVUnits(_stProtocolFee);
        return FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint(state, _stTotalSupply);
    }

    /// @notice Converts a NAV value into tranche shares through the clamped share-conversion primitive
    function convertToShares(uint256 _value, uint256 _totalValue, uint256 _totalSupply, Math.Rounding _rounding) external pure returns (uint256 shares) {
        return ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _totalSupply, _rounding);
    }
}
