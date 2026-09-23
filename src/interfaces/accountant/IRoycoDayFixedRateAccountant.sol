// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "./IRoycoDayAccountant.sol";

/// @title IRoycoDayFixedRateAccountant
/// @notice Interface for the RoycoDayFixedRateAccountant contract that pays the senior tranche a fixed rate coupon underwritten by the junior tranche
interface IRoycoDayFixedRateAccountant is IRoycoDayAccountant {
    /**
     * @notice Initialization parameters for the Royco Fixed Rate Accountant
     * @custom:field standardParams - The standard initialization parameters shared by every Royco Day accountant
     * @custom:field stFixedRatePerSecondWAD - The senior tranche's fixed rate per second, accrued linearly within a settlement window and compounded at each coupon settlement, scaled to WAD precision
     * @custom:field lptYDM - The liquidity provider tranche's Yield Distribution Model (LPT YDM), responsible for determining the yield share (liquidity premium) payed from the excess yield to the liquidity provider tranche
     * @custom:field lptYDMInitializationData - The data used to initialize the LPT YDM for this market
     * @custom:field maxLPTYieldShareWAD - The maximum LPT yield share (liquidity premium) as a percentage of the excess yield, scaled to WAD precision
     */
    struct RoycoDayFixedRateAccountantInitParams {
        // Standard accountant parameters
        RoycoDayAccountantInitParams standardParams;
        // Fixed rate configuration
        uint64 stFixedRatePerSecondWAD;
        // Yield Distribution Model
        address lptYDM;
        bytes lptYDMInitializationData;
        // Maximum yield share (liquidity premium)
        uint64 maxLPTYieldShareWAD;
    }

    /**
     * @notice The namespaced storage for the RoycoDayFixedRateAccountant
     * @custom:storage-location erc7201:Royco.storage.RoycoDayFixedRateAccountantState
     * @custom:field lptYDM - The liquidity provider tranche's Yield Distribution Model (LPT YDM), responsible for determining the yield share (liquidity premium) payed from the excess yield to the liquidity provider tranche
     * @custom:field maxLPTYieldShareWAD - The maximum LPT yield share (liquidity premium) as a percentage of the excess yield, scaled to WAD precision
     * @custom:field lastYieldShareAccrualTimestamp - The timestamp at which the time-weighted yield share accumulator was last updated
     * @custom:field stFixedRatePerSecondWAD - The senior tranche's fixed rate per second, accrued linearly within a settlement window and compounded at each coupon settlement, scaled to WAD precision
     * @custom:field lastCouponSettlementTimestamp - The timestamp at which the senior tranche's coupon was last settled, opening the current accrual window
     * @custom:field lastPremiumPaymentTimestamp - The timestamp at which the last liquidity premium payment occurred
     * @custom:field twLPTYieldShareAccruedWAD - The time-weighted liquidity provider tranche yield share (LPT YDM output) since the last premium payment, scaled to WAD precision
     */
    struct RoycoDayFixedRateAccountantState {
        // Slot 0
        address lptYDM;
        uint64 maxLPTYieldShareWAD;
        uint32 lastYieldShareAccrualTimestamp;
        // Slot 1 (uint128 holds over 1e13 years of the config-capped WAD-per-second accrual)
        uint64 stFixedRatePerSecondWAD;
        uint32 lastCouponSettlementTimestamp;
        uint32 lastPremiumPaymentTimestamp;
        uint128 twLPTYieldShareAccruedWAD;
    }

    /**
     * @notice Emitted when the LPT share of the excess yield (the liquidity premium) is accrued based on the market's liquidityUtilization since the last accrual
     * @param lptYieldShareWAD LPT's instantaneous yield share (LPT YDM output) based on liquidityUtilization since the last accrual
     * @param twLPTYieldShareAccruedWAD The time-weighted LPT yield share accrued since the last liquidity premium payment
     */
    event LPTYieldShareAccrued(uint256 lptYieldShareWAD, uint256 twLPTYieldShareAccruedWAD);

    /// @notice Emitted when the LPT YDM (liquidity provider tranche Yield Distribution Model) address is updated
    /// @param lptYDM The new LPT YDM address
    event LiquidityProviderTrancheYDMUpdated(address lptYDM);

    /// @notice Emitted when the maximum LPT yield share (liquidity premium) is updated
    /// @param maxLPTYieldShareWAD The new maximum LPT yield share (liquidity premium) as a percentage of the excess yield, scaled to WAD precision
    event MaxLPTYieldShareUpdated(uint64 maxLPTYieldShareWAD);

    /// @notice Emitted when the senior tranche's fixed rate is updated
    /// @param stFixedRatePerSecondWAD The new senior tranche fixed rate per second, scaled to WAD precision
    event SeniorTrancheFixedRateUpdated(uint64 stFixedRatePerSecondWAD);

    /// @notice Thrown when the accountant's protocol fee configuration is invalid (the junior tranche protocol fee must be zero, the knob is inert in this flavor)
    error INVALID_PROTOCOL_FEE_CONFIG();

    /// @notice Thrown when the accountant's yield share configuration is invalid (the maximum LPT yield share must be at most 100%)
    error INVALID_MAX_YIELD_SHARE_CONFIG();

    /**
     * @notice Updates the senior tranche's fixed rate for this market
     * @dev The new rate applies to the entire in-flight accrual window, so it should be updated right after a coupon settlement
     * @dev Only callable by a designated admin
     * @param _stFixedRatePerSecondWAD The new senior tranche fixed rate per second, scaled to WAD precision
     */
    function setSeniorTrancheFixedRate(uint64 _stFixedRatePerSecondWAD) external;

    /**
     * @notice Updates the LPT YDM (Liquidity Provider Tranche Yield Distribution Model) for this market
     * @dev Only callable by a designated admin
     * @param _lptYDM The new LPT YDM address to set
     * @param _lptYDMInitializationData The data used to initialize the new LPT YDM for this market
     */
    function setLiquidityProviderTrancheYDM(address _lptYDM, bytes calldata _lptYDMInitializationData) external;

    /**
     * @notice Updates the maximum LPT yield share (liquidity premium) for this market
     * @dev Only callable by a designated admin
     * @param _maxLPTYieldShareWAD The new maximum LPT yield share (liquidity premium) as a percentage of the excess yield, scaled to WAD precision
     */
    function setMaxLPTYieldShare(uint64 _maxLPTYieldShareWAD) external;

    /// @notice Returns the fixed rate accountant's own state (the fixed rate, the LPT YDM, the maximum yield share, and the accrual checkpoints)
    /// @return fixedRateState The state of the fixed rate accountant
    function getRoycoDayFixedRateAccountantState() external view returns (RoycoDayFixedRateAccountantState memory fixedRateState);
}
