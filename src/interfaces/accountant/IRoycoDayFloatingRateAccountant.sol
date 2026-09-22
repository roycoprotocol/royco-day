// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "./IRoycoDayAccountant.sol";

/// @title IRoycoDayFloatingRateAccountant
/// @notice Interface for the RoycoDayFloatingRateAccountant contract that distributes the floating senior yield via the JT and LPT YDMs
interface IRoycoDayFloatingRateAccountant is IRoycoDayAccountant {
    /**
     * @notice Initialization parameters for the Royco Floating Rate Accountant
     * @custom:field standardParams - The standard initialization parameters shared by every Royco Day accountant
     * @custom:field jtYDM - The junior tranche's Yield Distribution Model (JT YDM), responsible for determining the yield share (risk premium) payed from the senior tranche yield to the junior tranche
     * @custom:field jtYDMInitializationData - The data used to initialize the JT YDM for this market
     * @custom:field lptYDM - The liquidity provider tranche's Yield Distribution Model (LPT YDM), responsible for determining the yield share (liquidity premium) payed from the senior tranche yield to the liquidity provider tranche
     * @custom:field lptYDMInitializationData - The data used to initialize the LPT YDM for this market
     * @custom:field maxJTYieldShareWAD - The maximum JT yield share (risk premium) as a percentage of senior appreciation, scaled to WAD precision
     * @custom:field maxLPTYieldShareWAD - The maximum LPT yield share (liquidity premium) as a percentage of senior appreciation, scaled to WAD precision
     */
    struct RoycoDayFloatingRateAccountantInitParams {
        // Standard accountant parameters
        RoycoDayAccountantInitParams standardParams;
        // Yield Distribution Models
        address jtYDM;
        bytes jtYDMInitializationData;
        address lptYDM;
        bytes lptYDMInitializationData;
        // Maximum yield shares (risk and liquidity premiums)
        uint64 maxJTYieldShareWAD;
        uint64 maxLPTYieldShareWAD;
    }

    /**
     * @notice The namespaced storage for the RoycoDayFloatingRateAccountant
     * @custom:storage-location erc7201:Royco.storage.RoycoDayFloatingRateAccountantState
     * @custom:field jtYDM - The junior tranche's Yield Distribution Model (JT YDM), responsible for determining the yield share (risk premium) payed from the senior tranche yield to the junior tranche
     * @custom:field maxJTYieldShareWAD - The maximum JT yield share (risk premium) as a percentage of senior appreciation, scaled to WAD precision
     * @custom:field lastYieldShareAccrualTimestamp - The timestamp at which the time-weighted yield share accumulators were last updated
     * @custom:field lptYDM - The liquidity provider tranche's Yield Distribution Model (LPT YDM), responsible for determining the yield share (liquidity premium) payed from the senior tranche yield to the liquidity provider tranche
     * @custom:field maxLPTYieldShareWAD - The maximum LPT yield share (liquidity premium) as a percentage of senior appreciation, scaled to WAD precision
     * @custom:field lastPremiumPaymentTimestamp - The timestamp at which the last premium payments occurred (the risk and liquidity premiums are always paid together)
     * @custom:field twJTYieldShareAccruedWAD - The time-weighted junior tranche yield share (JT YDM output) since the last premium payment, scaled to WAD precision
     * @custom:field twLPTYieldShareAccruedWAD - The time-weighted liquidity provider tranche yield share (LPT YDM output) since the last premium payment, scaled to WAD precision
     */
    struct RoycoDayFloatingRateAccountantState {
        // Slot 0
        address jtYDM;
        uint64 maxJTYieldShareWAD;
        uint32 lastYieldShareAccrualTimestamp;
        // Slot 1
        address lptYDM;
        uint64 maxLPTYieldShareWAD;
        uint32 lastPremiumPaymentTimestamp;
        // Slot 2 (uint128 holds over 1e13 years of the config-capped WAD-per-second accrual)
        uint128 twJTYieldShareAccruedWAD;
        uint128 twLPTYieldShareAccruedWAD;
    }

    /**
     * @notice Emitted when the JT and LPT shares of ST yield (the risk and liquidity premiums) are accrued based on the market's coverageUtilization and liquidityUtilization since the last accrual
     * @param jtYieldShareWAD JT's instantaneous yield share (JT YDM output) based on coverageUtilization since the last accrual
     * @param twJTYieldShareAccruedWAD The time-weighted JT yield share accrued since the last yield distribution
     * @param lptYieldShareWAD LPT's instantaneous yield share (LPT YDM output) based on liquidityUtilization since the last accrual
     * @param twLPTYieldShareAccruedWAD The time-weighted LPT yield share accrued since the last liquidity premium payment
     */
    event YieldSharesAccrued(uint256 jtYieldShareWAD, uint256 twJTYieldShareAccruedWAD, uint256 lptYieldShareWAD, uint256 twLPTYieldShareAccruedWAD);

    /// @notice Emitted when the junior tranche yield distribution model is updated
    /// @param jtYDM The new junior tranche's YDM address
    event JuniorTrancheYDMUpdated(address jtYDM);

    /// @notice Emitted when the LPT YDM (liquidity provider tranche Yield Distribution Model) address is updated
    /// @param lptYDM The new LPT YDM address
    event LiquidityProviderTrancheYDMUpdated(address lptYDM);

    /**
     * @notice Emitted when the maximum JT and LPT yield shares (premiums) are updated
     * @param maxJTYieldShareWAD The new maximum JT yield share (risk premium) as a percentage of senior appreciation, scaled to WAD precision
     * @param maxLPTYieldShareWAD The new maximum LPT yield share (liquidity premium) as a percentage of senior appreciation, scaled to WAD precision
     */
    event MaxYieldSharesUpdated(uint64 maxJTYieldShareWAD, uint64 maxLPTYieldShareWAD);

    /// @notice Thrown when the accountant's yield share configuration is invalid (the maximum JT and LPT yield shares must sum to at most 100%)
    error INVALID_MAX_YIELD_SHARE_CONFIG();

    /// @notice Thrown when the junior and liquidity provider tranche YDMs are identical
    error YDMS_CANNOT_BE_IDENTICAL();

    /// @notice Thrown when the combined risk and liquidity premiums exceed the senior gain they are drawn from: the JT and LPT yield shares must sum to at most 100% of senior appreciation
    error PREMIUMS_EXCEED_SENIOR_YIELD();

    /**
     * @notice Updates the JT YDM (Junior Tranche Yield Distribution Model) for this market
     * @dev Only callable by a designated admin
     * @param _jtYDM The new JT YDM address to set
     * @param _jtYDMInitializationData The data used to initialize the new JT YDM for this market
     */
    function setJuniorTrancheYDM(address _jtYDM, bytes calldata _jtYDMInitializationData) external;

    /**
     * @notice Updates the LPT YDM (Liquidity Provider Tranche Yield Distribution Model) for this market
     * @dev Only callable by a designated admin
     * @param _lptYDM The new LPT YDM address to set
     * @param _lptYDMInitializationData The data used to initialize the new LPT YDM for this market
     */
    function setLiquidityProviderTrancheYDM(address _lptYDM, bytes calldata _lptYDMInitializationData) external;

    /**
     * @notice Updates the maximum JT and LPT yield shares (premiums) for this market
     * @dev Only callable by a designated admin
     * @param _maxJTYieldShareWAD The new maximum JT yield share (risk premium) as a percentage of senior appreciation, scaled to WAD precision
     * @param _maxLPTYieldShareWAD The new maximum LPT yield share (liquidity premium) as a percentage of senior appreciation, scaled to WAD precision
     */
    function setMaxYieldShares(uint64 _maxJTYieldShareWAD, uint64 _maxLPTYieldShareWAD) external;

    /// @notice Returns the floating rate accountant's own state (the YDMs, the maximum yield shares, and the yield share accrual checkpoints)
    /// @return floatingRateState The state of the floating rate accountant
    function getRoycoDayFloatingRateAccountantState() external view returns (RoycoDayFloatingRateAccountantState memory floatingRateState);
}
