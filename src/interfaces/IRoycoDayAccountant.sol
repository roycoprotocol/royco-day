// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { MarketState, Operation, SyncedAccountingState } from "../libraries/Types.sol";
import { NAV_UNIT } from "../libraries/Units.sol";

/**
 * @title IRoycoDayAccountant
 * @notice Interface for the RoycoDayAccountant contract that manages accounting, coverage, and liquidity requirements for a Royco market
 */
interface IRoycoDayAccountant {
    /**
     * @notice Initialization parameters for the Royco Accountant
     * @custom:field minCoverageWAD - The coverage ratio that the senior tranche is expected to be protected by, scaled to WAD precision
     * @custom:field betaWAD - The junior tranche's sensitivity to the same downside stress that affects the senior tranche, scaled to WAD precision
     *                         For example, beta is 0 when JT is in the RFR and 1 when JT is in the same opportunity as senior
     * @custom:field liquidationCoverageUtilizationWAD - The liquidation coverageUtilization threshold for this market, scaled to WAD precision
     * @custom:field minLiquidityWAD - The liquidity ratio that the senior tranche is expected to be provided liquidity by, scaled to WAD precision
     * @custom:field jtYDM - The junior tranche's Yield Distribution Model (JT YDM), responsible for determining the yield share (risk premium) payed from the senior tranche yield to the junior tranche
     * @custom:field jtYDMInitializationData - The data used to initialize the JT YDM for this market
     * @custom:field ltYDM - The liquidity tranche's Yield Distribution Model (LT YDM), responsible for determining the yield share (liquidity premium) payed from the senior tranche yield to the liquidity tranche
     * @custom:field ltYDMInitializationData - The data used to initialize the LT YDM for this market
     * @custom:field fixedTermDurationSeconds - The duration of a fixed term for this market in seconds
     * @custom:field stNAVDustTolerance - The worst case dust tolerance for stRawNAV from underlying NAV quoting/rounding
     * @custom:field jtNAVDustTolerance - The worst case dust tolerance for jtRawNAV from underlying NAV quoting/rounding
     * @custom:field ltNAVDustTolerance - The worst case dust tolerance for ltRawNAV from underlying NAV quoting/rounding
     * @custom:field stProtocolFeeWAD - The market's configured protocol fee percentage taken from yield earned by the senior tranche, scaled to WAD precision
     * @custom:field jtProtocolFeeWAD - The market's configured protocol fee percentage taken from yield earned by the junior tranche, scaled to WAD precision
     * @custom:field jtYieldShareProtocolFeeWAD - The market's configured protocol fee percentage taken from the yield share (risk premium) payed from the senior tranche yield to the junior tranche, scaled to WAD precision
     * @custom:field ltProtocolFeeWAD - The market's configured protocol fee percentage taken from yield earned by the liquidity tranche, scaled to WAD precision
     * @custom:field ltYieldShareProtocolFeeWAD - The market's configured protocol fee percentage taken from the yield share (liquidity premium) payed from the senior tranche yield to the liquidity tranche, scaled to WAD precision
     */
    struct RoycoDayAccountantInitParams {
        // Coverage configuration
        uint64 minCoverageWAD;
        uint96 betaWAD;
        uint256 liquidationCoverageUtilizationWAD;
        // Liquidity configuration
        uint64 minLiquidityWAD;
        // Yield Distribution Models
        address jtYDM;
        bytes jtYDMInitializationData;
        address ltYDM;
        bytes ltYDMInitializationData;
        // Fixed term duration
        uint24 fixedTermDurationSeconds;
        // Dust tolerances
        NAV_UNIT stNAVDustTolerance;
        NAV_UNIT jtNAVDustTolerance;
        NAV_UNIT ltNAVDustTolerance;
        // Protocol fees
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 jtYieldShareProtocolFeeWAD;
        uint64 ltProtocolFeeWAD;
        uint64 ltYieldShareProtocolFeeWAD;
    }

    /**
     * @notice Storage state for the Royco Accountant
     * @custom:storage-location erc7201:Royco.storage.RoycoDayAccountantState
     * @custom:field stProtocolFeeWAD - The market's configured protocol fee percentage charged from yield earned by the senior tranche, scaled to WAD precision
     * @custom:field jtProtocolFeeWAD - The market's configured protocol fee percentage charged from yield earned by the junior tranche, scaled to WAD precision
     * @custom:field jtYieldShareProtocolFeeWAD - The market's configured protocol fee percentage charged from the yield share (risk premium) payed from the senior tranche yield to the junior tranche, scaled to WAD precision
     * @custom:field ltProtocolFeeWAD - The market's configured protocol fee percentage charged from yield earned by the liquidity tranche, scaled to WAD precision
     * @custom:field ltYieldShareProtocolFeeWAD - The market's configured protocol fee percentage charged from the yield share (liquidity premium) payed from the senior tranche yield to the liquidity tranche, scaled to WAD precision
     * @custom:field minCoverageWAD - The coverage percentage that the senior tranche is expected to be protected by, scaled to WAD precision
     * @custom:field fixedTermDurationSeconds - The duration of a fixed term for this market in seconds
     * @custom:field lastMarketState - The last recorded state of this market (perpetual or fixed term)
     * @custom:field fixedTermEndTimestamp - The end timestamp of the currently ongoing fixed term (set to 0 if the market is in a perpetual state)
     * @custom:field jtYDM - The junior tranche's Yield Distribution Model (JT YDM), responsible for determining the yield share (risk premium) payed from the senior tranche yield to the junior tranche
     * @custom:field betaWAD - JT's percentage sensitivity to the same downside stress that affects ST, scaled to WAD precision
     *                         For example, beta is 0 when JT is in the RFR and 1e18 (100%) when JT is in the same opportunity as senior
     * @custom:field ltYDM - The liquidity tranche's Yield Distribution Model (LT YDM), responsible for determining the yield share (liquidity premium) payed from the senior tranche yield to the liquidity tranche
     * @custom:field minLiquidityWAD - The liquidity percentage that the senior tranche is expected to be provided liquidity by, scaled to WAD precision
     * @custom:field twJTYieldShareAccruedWAD - The time-weighted junior tranche yield share (JT YDM output) since the last yield distribution, scaled to WAD precision
     * @custom:field lastJTYieldShareAccrualTimestamp - The timestamp at which the time-weighted JT yield share accumulator was last updated
     * @custom:field lastRiskPremiumPaymentTimestamp - The timestamp at which the last JT risk premium payment occurred
     * @custom:field liquidationCoverageUtilizationWAD - The liquidation coverageUtilization threshold for this market, scaled to WAD precision
     * @custom:field lastSTRawNAV - The last recorded pure NAV (excluding any coverage taken and yield shared) of the senior tranche
     * @custom:field lastJTRawNAV - The last recorded pure NAV (excluding any coverage given and yield shared) of the junior tranche
     * @custom:field lastSTEffectiveNAV - The last recorded effective NAV (including any prior applied coverage, ST yield distribution, and uncovered losses) of the senior tranche
     * @custom:field lastJTEffectiveNAV - The last recorded effective NAV (including any prior provided coverage, JT yield, ST yield distribution, and JT losses) of the junior tranche
     * @custom:field lastJTCoverageImpermanentLoss - The impermanent loss that JT has suffered after providing coverage for ST losses
     *                                           This represents the claim on capital that the junior tranche has on future ST recoveries
     * @custom:field lastLTRawNAV - The last recorded raw NAV of the liquidity tranche: the mark-to-market value of its invested assets
     * @custom:field stNAVDustTolerance - The worst case dust tolerance for stRawNAV from underlying NAV quoting/rounding
     * @custom:field jtNAVDustTolerance - The worst case dust tolerance for jtRawNAV from underlying NAV quoting/rounding
     * @custom:field effectiveNAVDustTolerance - Effective NAV deltas are claim-weighted linear combinations of stRawNAV and jtRawNAV deltas, so the worst-case dust is bounded by the sum of the raw NAV dust tolerances
     * @custom:field ltNAVDustTolerance - The worst case dust tolerance for ltRawNAV from underlying NAV quoting/rounding
     */
    struct RoycoDayAccountantState {
        // Slot 0
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 jtYieldShareProtocolFeeWAD;
        uint64 ltProtocolFeeWAD;
        // Slot 1
        uint64 ltYieldShareProtocolFeeWAD;
        uint64 minCoverageWAD;
        uint24 fixedTermDurationSeconds;
        MarketState lastMarketState;
        uint32 fixedTermEndTimestamp;
        // Slot 2
        address jtYDM;
        uint96 betaWAD;
        // Slot 3
        address ltYDM;
        uint64 minLiquidityWAD;
        // Slot 4
        uint192 twJTYieldShareAccruedWAD;
        uint32 lastJTYieldShareAccrualTimestamp;
        uint32 lastRiskPremiumPaymentTimestamp;
        // Slot 5-15
        uint256 liquidationCoverageUtilizationWAD;
        NAV_UNIT lastSTRawNAV;
        NAV_UNIT lastJTRawNAV;
        NAV_UNIT lastSTEffectiveNAV;
        NAV_UNIT lastJTEffectiveNAV;
        NAV_UNIT lastJTCoverageImpermanentLoss;
        NAV_UNIT lastLTRawNAV;
        NAV_UNIT stNAVDustTolerance;
        NAV_UNIT jtNAVDustTolerance;
        NAV_UNIT effectiveNAVDustTolerance;
        NAV_UNIT ltNAVDustTolerance;
    }

    /**
     * @notice Emitted when JT's share of ST yield is accrued based on the market's coverageUtilization since the last accrual
     * @param jtYieldShareWAD JT's instantaneous yield share (JT YDM output) based on coverageUtilization since the last accrual
     * @param twJTYieldShareAccruedWAD The time-weighted JT yield share accrued since the last yield distribution
     */
    event JuniorTrancheYieldShareAccrued(uint256 jtYieldShareWAD, uint256 twJTYieldShareAccruedWAD);

    /// @notice Emitted when a fixed term regime is commenced by this market
    /// @param fixedTermEndTimestamp The end timestamp of the new fixed term regime
    event FixedTermCommenced(uint32 fixedTermEndTimestamp);

    /// @notice Emitted when a pre or post operation tranche accounting synchronization is executed
    /// @param resultingState The resulting market state after synchronizing the tranche accounting
    event TrancheAccountingSynced(SyncedAccountingState resultingState);

    /// @notice Emitted when the junior tranche yield distribution model is updated
    /// @param jtYDM The new junior tranche's YDM address
    event JuniorTrancheYDMUpdated(address jtYDM);

    /// @notice Emitted when the senior tranche protocol fee percentage is updated
    /// @param stProtocolFeeWAD The new protocol fee percentage charged on senior tranche yield, scaled to WAD precision
    event SeniorTrancheProtocolFeeUpdated(uint64 stProtocolFeeWAD);

    /// @notice Emitted when the junior tranche protocol fee percentage is updated
    /// @param jtProtocolFeeWAD The new protocol fee percentage charged on junior tranche yield, scaled to WAD precision
    event JuniorTrancheProtocolFeeUpdated(uint64 jtProtocolFeeWAD);

    /// @notice Emitted when the junior tranche yield share (risk premium) protocol fee percentage is updated
    /// @param jtYieldShareProtocolFeeWAD The new protocol fee percentage charged from the yield share (risk premium) payed from the senior tranche yield to the junior tranche, scaled to WAD precision
    event JuniorTrancheYieldShareProtocolFeeUpdated(uint64 jtYieldShareProtocolFeeWAD);

    /// @notice Emitted when the coverage percentage requirement is updated
    /// @param minCoverageWAD The new coverage percentage, scaled to WAD precision
    event CoverageUpdated(uint64 minCoverageWAD);

    /// @notice Emitted when the beta sensitivity parameter is updated
    /// @param betaWAD The new beta parameter representing JT's sensitivity to downside stress, scaled to WAD precision
    event BetaUpdated(uint96 betaWAD);

    /// @notice Emitted when the liquidation threshold parameter is updated
    /// @param liquidationCoverageUtilizationWAD The new liquidation coverageUtilization threshold for this market, scaled to WAD precision
    event LiquidationCoverageUtilizationUpdated(uint256 liquidationCoverageUtilizationWAD);

    /// @notice Emitted when the fixed term duration is updated
    /// @param fixedTermDurationSeconds The new fixed term duration for this market in seconds
    event FixedTermDurationUpdated(uint24 fixedTermDurationSeconds);

    /// @notice Emitted when ST's dust tolerance is updated
    /// @param stNAVDustTolerance The dust tolerance in NAV units to account for minuscule deltas in the ST's underlying NAV calculations
    event SeniorTrancheDustToleranceUpdated(NAV_UNIT stNAVDustTolerance);

    /// @notice Emitted when JT's dust tolerance is updated
    /// @param jtNAVDustTolerance The dust tolerance in NAV units to account for minuscule deltas in the JT's underlying NAV calculations
    event JuniorTrancheDustToleranceUpdated(NAV_UNIT jtNAVDustTolerance);

    /// @notice Emitted when JT's coverage loss is realized and reset to zero when transitioning from a fixed term state to a perpetual state
    /// @param jtCoverageImpermanentLossErased The amount of JT coverage loss erased when transitioning from a fixed term state to a perpetual state
    event JuniorTrancheCoverageImpermanentLossReset(NAV_UNIT jtCoverageImpermanentLossErased);

    /// @notice Emitted when a fixed term regime is ended by this market
    event FixedTermEnded();

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

    /// @notice Thrown when the caller of the function is not the accountant's configured Royco Kernel
    error ONLY_ROYCO_KERNEL();

    /// @notice Thrown when the accountant's coverage configuration is invalid (can be due to incorrect coverage, beta, or liquidation coverageUtilization values)
    error INVALID_COVERAGE_CONFIG();

    /// @notice Thrown when the accountant's liquidity configuration is invalid (the minimum liquidity must be less than 100%)
    error INVALID_LIQUIDITY_CONFIG();

    /// @notice Thrown when the configured protocol fee exceeds the maximum
    error MAX_PROTOCOL_FEE_EXCEEDED();

    /// @notice Thrown when the junior and liquidity tranche YDMs are identical
    error YDMS_CANNOT_BE_IDENTICAL();

    /// @notice Thrown when the YDM failed to initialize
    /// @param data The return data of the reverting YDM initialization
    error FAILED_TO_INITIALIZE_YDM(bytes data);

    /// @notice Thrown when a YDM returns a yield share exceeding 100% of senior appreciation
    error INVALID_YDM_OUTPUT();

    /// @notice Thrown when the sum of the raw NAVs don't equal the sum of the effective NAVs of both tranches
    error NAV_CONSERVATION_VIOLATION();

    /// @notice Thrown when the operation and NAVs passed to post-op lead to an invalid state
    error INVALID_POST_OP_STATE(Operation _op);

    /// @notice Thrown when the market's coverage requirement is unsatisfied
    error COVERAGE_REQUIREMENT_UNSATISFIED();

    /// @notice Retrieves the address of the kernel tied to this accountant
    /// @return kernel The kernel that this accountant maintains mark-to-market NAV, JT coverage impermanent loss, and fee accounting for
    function KERNEL() external view returns (address kernel);

    /**
     * @notice Synchronizes the effective NAVs and impermanent losses of both tranches by marking them to market
     * @dev Must be called before any NAV mutating operation
     * @dev Accrues JT yield share over time based on the market's JT YDM output
     * @dev Persists updated NAV and impermanent loss checkpoints for the next sync to use as reference
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _ltRawNAV The liquidity tranche's current raw NAV: the pure value of its invested assets
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function preOpSyncTrancheAccounting(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV, NAV_UNIT _ltRawNAV) external returns (SyncedAccountingState memory state);

    /**
     * @notice Previews a synchronization of the effective NAVs and impermanent losses of both tranches by marking them to market
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _ltRawNAV The liquidity tranche's current raw NAV: the pure value of its invested assets
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function previewSyncTrancheAccounting(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV, NAV_UNIT _ltRawNAV) external view returns (SyncedAccountingState memory state);

    /**
     * @notice Applies post-operation (deposit or redemption) raw NAV deltas to effective NAV checkpoints
     * @dev Strictly interprets NAV deltas as deposits/redemptions instead of PNL
     * @param _op The operation being executed in between the pre and post operation synchronizations
     * @param _stRawNAV The post-op senior tranche's raw NAV
     * @param _jtRawNAV The post-op junior tranche's raw NAV
     * @param _ltRawNAV The post-op liquidity tranche's raw NAV
     * @param _stSelfLiquidationBonusNAV The self-liquidation bonus remitted to an ST LP on redemption after the liquidation coverageUtilization threshold has been breached, sourced from JT effective NAV
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function postOpSyncTrancheAccounting(
        Operation _op,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV,
        NAV_UNIT _stSelfLiquidationBonusNAV
    )
        external
        returns (SyncedAccountingState memory state);

    /**
     * @notice Applies post-operation (deposit or redemption) raw NAV deltas to effective NAV checkpoints and enforces the market's coverage condition
     * @dev Strictly interprets NAV deltas as deposits/redemptions instead of PNL
     * @dev Reverts if the coverage requirement is unsatisfied after the NAVs have been marked to market
     * @param _op The operation being executed in between the pre and post operation synchronizations
     * @param _stRawNAV The post-op senior tranche's raw NAV
     * @param _jtRawNAV The post-op junior tranche's raw NAV
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function postOpSyncTrancheAccountingAndEnforceCoverage(
        Operation _op,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV
    )
        external
        returns (SyncedAccountingState memory state);

    /**
     * @notice Returns if the market's coverage requirement is satisfied
     * @dev If this condition is unsatisfied, senior deposits and junior withdrawals must be blocked to prevent undercollateralized exposure
     * @return satisfied A boolean indicating whether the market's coverage requirement is satisfied based on the persisted NAV checkpoints
     */
    function isCoverageRequirementSatisfied() external view returns (bool satisfied);

    /**
     * @notice Returns if the market's liquidity requirement is satisfied
     * @dev If this condition is unsatisfied, liquidity tranche withdrawals must be gated to prevent the senior tranche's exit liquidity from falling below the configured minimum
     * @return satisfied A boolean indicating whether the market's liquidity requirement is satisfied based on the persisted NAV checkpoints
     */
    function isLiquidityRequirementSatisfied() external view returns (bool satisfied);

    /**
     * @notice Returns the maximum assets depositable into the senior tranche without violating the market's coverage requirement
     * @dev Always rounds in favor of senior tranche protection
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _ltRawNAV The liquidity tranche's current raw NAV: the pure value of its invested assets
     * @return maxSTDeposit The maximum assets depositable into the senior tranche without violating the market's coverage requirement
     */
    function maxSTDepositGivenCoverage(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV, NAV_UNIT _ltRawNAV) external view returns (NAV_UNIT maxSTDeposit);

    /**
     * @notice Returns the maximum assets withdrawable from the junior tranche without violating the market's coverage requirement
     * @dev Always rounds in favor of senior tranche protection
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _ltRawNAV The liquidity tranche's current raw NAV: the pure value of its invested assets
     * @param _jtClaimOnStUnits The total claims on ST assets that the junior tranche has denominated in NAV units
     * @param _jtClaimOnJtUnits The total claims on JT assets that the junior tranche has denominated in NAV units
     * @return totalNAVClaimable The maximum NAV that can be claimed from the junior tranche without violating the market's coverage requirement
     * @return stClaimable The maximum claims on ST assets that the junior tranche can withdraw, denominated in NAV units
     * @return jtClaimable The maximum claims on JT assets that the junior tranche can withdraw, denominated in NAV units
     */
    function maxJTWithdrawalGivenCoverage(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV,
        NAV_UNIT _jtClaimOnStUnits,
        NAV_UNIT _jtClaimOnJtUnits
    )
        external
        view
        returns (NAV_UNIT totalNAVClaimable, NAV_UNIT stClaimable, NAV_UNIT jtClaimable);

    /**
     * @notice Updates the JT YDM (Junior Tranche Yield Distribution Model) for this market
     * @dev Only callable by a designated admin
     * @param _jtYDM The new JT YDM address to set
     * @param _jtYDMInitializationData The data used to initialize the new JT YDM for this market
     */
    function setJuniorTrancheYDM(address _jtYDM, bytes calldata _jtYDMInitializationData) external;

    /**
     * @notice Updates the senior tranche protocol fee percentage for this market
     * @dev Only callable by a designated admin
     * @param _stProtocolFeeWAD The new protocol fee percentage charged on senior tranche yield, scaled to WAD precision
     */
    function setSeniorTrancheProtocolFee(uint64 _stProtocolFeeWAD) external;

    /**
     * @notice Updates the junior tranche protocol fee percentage for this market
     * @dev Only callable by a designated admin
     * @param _jtProtocolFeeWAD The new protocol fee percentage charged on junior tranche yield, scaled to WAD precision
     */
    function setJuniorTrancheProtocolFee(uint64 _jtProtocolFeeWAD) external;

    /**
     * @notice Updates the yield share (risk premium) protocol fee percentage for this market
     * @dev Only callable by a designated admin
     * @param _jtYieldShareProtocolFeeWAD The new protocol fee percentage charged on the yield share (risk premium) payed from senior tranche yield to the junior tranche, scaled to WAD precision
     */
    function setJTYieldShareProtocolFee(uint64 _jtYieldShareProtocolFeeWAD) external;

    /**
     * @notice Updates the coverage percentage requirement for this market
     * @dev Only callable by a designated admin
     * @param _minCoverageWAD The new coverage percentage, scaled to WAD precision
     */
    function setCoverage(uint64 _minCoverageWAD) external;

    /**
     * @notice Updates the beta sensitivity parameter for this market
     * @dev Only callable by a designated admin
     * @param _betaWAD The new beta parameter representing JT's sensitivity to downside stress, scaled to WAD precision
     */
    function setBeta(uint96 _betaWAD) external;

    /**
     * @notice Updates the liquidation coverageUtilization threshold for this market
     * @dev Only callable by a designated admin
     * @param _liquidationCoverageUtilizationWAD The new liquidation coverageUtilization threshold for this market, scaled to WAD precision
     */
    function setLiquidationCoverageUtilization(uint256 _liquidationCoverageUtilizationWAD) external;

    /**
     * @notice Updates the coverage configuration (coverage, beta, and liquidation coverageUtilization) for this market
     * @dev Only callable by a designated admin
     * @param _minCoverageWAD The new coverage percentage, scaled to WAD precision
     * @param _betaWAD The new beta parameter representing JT's sensitivity to downside stress, scaled to WAD precision
     * @param _liquidationCoverageUtilizationWAD The new liquidation coverageUtilization threshold for this market, scaled to WAD precision
     */
    function setCoverageConfiguration(uint64 _minCoverageWAD, uint96 _betaWAD, uint256 _liquidationCoverageUtilizationWAD) external;

    /**
     * @notice Updates the fixed term duration for this market
     * @dev Setting the fixed term duration to 0 will force the market into an eternally perpetual state
     * @dev Only callable by a designated admin
     * @param _fixedTermDurationSeconds The new fixed term duration for this market in seconds
     */
    function setFixedTermDuration(uint24 _fixedTermDurationSeconds) external;

    /**
     * @notice Updates ST's dust tolerance in NAV units to account for minuscule deltas in the underlying protocol's NAV calculations, due to rounding
     * @dev Can be safely set to 0 if the underlying investments do not exhibit rounding behavior
     * @dev Only callable by a designated admin
     * @param _stNAVDustTolerance The ST NAV tolerance for rounding discrepancies
     */
    function setSeniorTrancheDustTolerance(NAV_UNIT _stNAVDustTolerance) external;

    /**
     * @notice Updates JT's dust tolerance in NAV units to account for minuscule deltas in the underlying protocol's NAV calculations, due to rounding
     * @dev Can be safely set to 0 if the underlying investments do not exhibit rounding behavior
     * @dev Only callable by a designated admin
     * @param _jtNAVDustTolerance The JT NAV tolerance for rounding discrepancies
     */
    function setJuniorTrancheDustTolerance(NAV_UNIT _jtNAVDustTolerance) external;

    /**
     * @notice Returns the state of the accountant
     * @return state The state of the accountant
     */
    function getState() external pure returns (RoycoDayAccountantState memory state);
}
