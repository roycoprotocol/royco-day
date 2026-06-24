// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { MarketState, Operation, SyncedAccountingState } from "../libraries/Types.sol";
import { NAV_UNIT } from "../libraries/Units.sol";
import { IRoycoDawnAccountant } from "./IRoycoDawnAccountant.sol";

/**
 * @title IRoycoDayAccountant
 * @notice Interface for the RoycoDayAccountant contract that manages accounting, coverage, and liquidity requirements for a Royco market
 */
interface IRoycoDayAccountant is IRoycoDawnAccountant {
    /**
     * @notice Initialization parameters for the Royco Day Accountant
     * @custom:field dawnAccountantInitParams - The initialization parameters for the senior and junior tranche accounting inherited from the Dawn accountant
     * @custom:field ltProtocolFeeWAD - The market's configured protocol fee percentage taken from yield earned by the liquidity tranche, scaled to WAD precision
     * @custom:field ltYieldShareProtocolFeeWAD - The market's configured protocol fee percentage taken from the yield share (liquidity premium) payed from the senior tranche yield to the liquidity tranche, scaled to WAD precision
     * @custom:field minLiquidityWAD - The liquidity ratio that the senior tranche is expected to be provided liquidity by, scaled to WAD precision
     * @custom:field ltYDM - The liquidity tranche's Yield Distribution Model (LT YDM), responsible for determining the yield share (liquidity premium) payed from the senior tranche yield to the liquidity tranche
     * @custom:field ltYDMInitializationData - The data used to initialize the LT YDM for this market
     * @custom:field ltNAVDustTolerance - The worst case dust tolerance for ltRawNAV from underlying NAV quoting/rounding
     */
    struct RoycoDayAccountantInitParams {
        RoycoDawnAccountantInitParams dawnAccountantInitParams;
        uint64 ltProtocolFeeWAD;
        uint64 ltYieldShareProtocolFeeWAD;
        uint64 minLiquidityWAD;
        address ltYDM;
        bytes ltYDMInitializationData;
        NAV_UNIT ltNAVDustTolerance;
    }

    /**
     * @notice Storage state for the Royco Day Accountant
     * @custom:storage-location erc7201:Royco.storage.RoycoDayAccountantState
     * @custom:field ltYDM - The liquidity tranche's Yield Distribution Model (LT YDM), responsible for determining the yield share (liquidity premium) payed from the senior tranche yield to the liquidity tranche
     * @custom:field minLiquidityWAD - The liquidity percentage that the senior tranche is expected to be provided liquidity by, scaled to WAD precision
     * @custom:field ltProtocolFeeWAD - The market's configured protocol fee percentage charged from yield earned by the liquidity tranche, scaled to WAD precision
     * @custom:field ltYieldShareProtocolFeeWAD - The market's configured protocol fee percentage charged from the yield share (liquidity premium) payed from the senior tranche yield to the liquidity tranche, scaled to WAD precision
     * @custom:field lastLTRawNAV - The last recorded raw NAV of the liquidity tranche: the mark-to-market value of its invested assets
     * @custom:field ltNAVDustTolerance - The worst case dust tolerance for ltRawNAV from underlying NAV quoting/rounding
     */
    struct RoycoDayAccountantState {
        address ltYDM;
        uint64 minLiquidityWAD;
        uint64 ltProtocolFeeWAD;
        uint64 ltYieldShareProtocolFeeWAD;
        NAV_UNIT lastLTRawNAV;
        NAV_UNIT ltNAVDustTolerance;
    }

    /// @notice Emitted when the LT YDM (liquidity tranche Yield Distribution Model) address is updated
    /// @param ltYDM The new LT YDM address
    event LiquidityTrancheYDMUpdated(address ltYDM);

    /// @notice Emitted when the liquidity tranche protocol fee percentage is updated
    /// @param ltProtocolFeeWAD The new protocol fee percentage charged on liquidity tranche yield, scaled to WAD precision
    event LiquidityTrancheProtocolFeeUpdated(uint64 ltProtocolFeeWAD);

    /// @notice Emitted when the yield share (liquidity premium) protocol fee percentage is updated
    /// @param ltYieldShareProtocolFeeWAD The new protocol fee percentage charged from the yield share (liquidity premium) payed from the senior tranche yield to the liquidity tranche, scaled to WAD precision
    event LiquidityTrancheYieldShareProtocolFeeUpdated(uint64 ltYieldShareProtocolFeeWAD);

    /// @notice Emitted when the liquidity percentage requirement is updated
    /// @param minLiquidityWAD The new liquidity percentage, scaled to WAD precision
    event LiquidityUpdated(uint64 minLiquidityWAD);

    /// @notice Emitted when LT's dust tolerance is updated
    /// @param ltNAVDustTolerance The dust tolerance in NAV units to account for minuscule deltas in the LT's underlying NAV calculations
    event LiquidityTrancheDustToleranceUpdated(NAV_UNIT ltNAVDustTolerance);

    /// @notice Thrown when the accountant's liquidity configuration is invalid (the minimum liquidity must be less than 100%)
    error INVALID_LIQUIDITY_CONFIG();

    /**
     * @notice Returns if the market's liquidity requirement is satisfied
     * @dev If this condition is unsatisfied, liquidity tranche withdrawals must be gated to prevent the senior tranche's exit liquidity from falling below the configured minimum
     * @return satisfied A boolean indicating whether the market's liquidity requirement is satisfied based on the persisted NAV checkpoints
     */
    function isLiquidityRequirementSatisfied() external view returns (bool satisfied);
}
