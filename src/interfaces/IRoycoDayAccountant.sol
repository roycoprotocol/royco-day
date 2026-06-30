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
     * @custom:field coverageLiquidationUtilizationWAD - The liquidation coverageUtilization threshold for this market, scaled to WAD precision
     * @custom:field minLiquidityWAD - The percentage of the senior tranche NAV that must be in the liquidity tranche's market making inventory, scaled to WAD precision
     * @custom:field jtYDM - The junior tranche's Yield Distribution Model (JT YDM), responsible for determining the yield share (risk premium) payed from the senior tranche yield to the junior tranche
     * @custom:field jtYDMInitializationData - The data used to initialize the JT YDM for this market
     * @custom:field ltYDM - The liquidity tranche's Yield Distribution Model (LT YDM), responsible for determining the yield share (liquidity premium) payed from the senior tranche yield to the liquidity tranche
     * @custom:field ltYDMInitializationData - The data used to initialize the LT YDM for this market
     * @custom:field maxJTYieldShareWAD - The maximum JT yield share (risk premium) as a percentage of senior appreciation, scaled to WAD precision
     * @custom:field maxLTYieldShareWAD - The maximum LT yield share (liquidity premium) as a percentage of senior appreciation, scaled to WAD precision
     * @custom:field fixedTermDurationSeconds - The duration of a fixed term for this market in seconds
     * @custom:field stNAVDustTolerance - The worst case dust tolerance for stRawNAV from underlying NAV quoting/rounding
     * @custom:field jtNAVDustTolerance - The worst case dust tolerance for jtRawNAV from underlying NAV quoting/rounding
     * @custom:field stProtocolFeeWAD - The market's configured protocol fee percentage taken from yield earned by the senior tranche, scaled to WAD precision
     * @custom:field jtProtocolFeeWAD - The market's configured protocol fee percentage taken from yield earned by the junior tranche, scaled to WAD precision
     * @custom:field jtYieldShareProtocolFeeWAD - The market's configured protocol fee percentage taken from the yield share (risk premium) payed from the senior tranche yield to the junior tranche, scaled to WAD precision
     * @custom:field ltYieldShareProtocolFeeWAD - The market's configured protocol fee percentage taken from the yield share (liquidity premium) payed from the senior tranche yield to the liquidity tranche, scaled to WAD precision
     */
    struct RoycoDayAccountantInitParams {
        // Coverage configuration
        uint64 minCoverageWAD;
        uint256 coverageLiquidationUtilizationWAD;
        // Liquidity configuration
        uint64 minLiquidityWAD;
        // Yield Distribution Models
        address jtYDM;
        bytes jtYDMInitializationData;
        address ltYDM;
        bytes ltYDMInitializationData;
        // Maximum yield shares (premiums)
        uint64 maxJTYieldShareWAD;
        uint64 maxLTYieldShareWAD;
        // Fixed term duration
        uint24 fixedTermDurationSeconds;
        // Dust tolerances
        NAV_UNIT stNAVDustTolerance;
        NAV_UNIT jtNAVDustTolerance;
        // Protocol fees
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 jtYieldShareProtocolFeeWAD;
        uint64 ltYieldShareProtocolFeeWAD;
    }

    /**
     * @notice Storage state for the Royco Accountant
     * @custom:storage-location erc7201:Royco.storage.RoycoDayAccountantState
     * @custom:field stProtocolFeeWAD - The market's configured protocol fee percentage charged from yield earned by the senior tranche, scaled to WAD precision
     * @custom:field jtProtocolFeeWAD - The market's configured protocol fee percentage charged from yield earned by the junior tranche, scaled to WAD precision
     * @custom:field jtYieldShareProtocolFeeWAD - The market's configured protocol fee percentage charged from the yield share (risk premium) payed from the senior tranche yield to the junior tranche, scaled to WAD precision
     * @custom:field ltYieldShareProtocolFeeWAD - The market's configured protocol fee percentage charged from the yield share (liquidity premium) payed from the senior tranche yield to the liquidity tranche, scaled to WAD precision
     * @custom:field minCoverageWAD - The coverage percentage that the senior tranche is expected to be protected by, scaled to WAD precision
     * @custom:field fixedTermDurationSeconds - The duration of a fixed term for this market in seconds
     * @custom:field lastMarketState - The last recorded state of this market (perpetual or fixed term)
     * @custom:field fixedTermEndTimestamp - The end timestamp of the currently ongoing fixed term (set to 0 if the market is in a perpetual state)
     * @custom:field jtYDM - The junior tranche's Yield Distribution Model (JT YDM), responsible for determining the yield share (risk premium) payed from the senior tranche yield to the junior tranche
     * @custom:field ltYDM - The liquidity tranche's Yield Distribution Model (LT YDM), responsible for determining the yield share (liquidity premium) payed from the senior tranche yield to the liquidity tranche
     * @custom:field minLiquidityWAD - The percentage of the senior tranche NAV that must be in the liquidity tranche's market making inventory, scaled to WAD precision
     * @custom:field twJTYieldShareAccruedWAD - The time-weighted junior tranche yield share (JT YDM output) since the last premium payment, scaled to WAD precision
     * @custom:field maxJTYieldShareWAD - The maximum JT yield share (risk premium) as a percentage of senior appreciation, scaled to WAD precision
     * @custom:field twLTYieldShareAccruedWAD - The time-weighted liquidity tranche yield share (LT YDM output) since the last premium payment, scaled to WAD precision
     * @custom:field maxLTYieldShareWAD - The maximum LT yield share (liquidity premium) as a percentage of senior appreciation, scaled to WAD precision
     * @custom:field lastYieldShareAccrualTimestamp - The timestamp at which the time-weighted yield share accumulators were last updated
     * @custom:field lastPremiumPaymentTimestamp - The timestamp at which the last premium payments occurred (the risk and liquidity premiums are always paid together)
     * @custom:field coverageLiquidationUtilizationWAD - The liquidation coverageUtilization threshold for this market, scaled to WAD precision
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
     */
    struct RoycoDayAccountantState {
        // Slot 0
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 jtYieldShareProtocolFeeWAD;
        uint64 ltYieldShareProtocolFeeWAD;
        // Slot 1
        uint64 minCoverageWAD;
        uint24 fixedTermDurationSeconds;
        MarketState lastMarketState;
        uint32 fixedTermEndTimestamp;
        uint32 lastYieldShareAccrualTimestamp;
        uint32 lastPremiumPaymentTimestamp;
        // Slot 2
        address jtYDM;
        // Slot 3
        address ltYDM;
        uint64 minLiquidityWAD;
        // Slot 4
        uint192 twJTYieldShareAccruedWAD;
        uint64 maxJTYieldShareWAD;
        // Slot 5
        uint192 twLTYieldShareAccruedWAD;
        uint64 maxLTYieldShareWAD;
        // Slot 6-16
        uint256 coverageLiquidationUtilizationWAD;
        NAV_UNIT lastSTRawNAV;
        NAV_UNIT lastJTRawNAV;
        NAV_UNIT lastSTEffectiveNAV;
        NAV_UNIT lastJTEffectiveNAV;
        NAV_UNIT lastJTCoverageImpermanentLoss;
        NAV_UNIT lastLTRawNAV;
        NAV_UNIT stNAVDustTolerance;
        NAV_UNIT jtNAVDustTolerance;
        NAV_UNIT effectiveNAVDustTolerance;
    }

    /**
     * @notice Emitted when JT's share of ST yield is accrued based on the market's coverageUtilization since the last accrual
     * @param jtYieldShareWAD JT's instantaneous yield share (JT YDM output) based on coverageUtilization since the last accrual
     * @param twJTYieldShareAccruedWAD The time-weighted JT yield share accrued since the last yield distribution
     */
    event JuniorTrancheYieldShareAccrued(uint256 jtYieldShareWAD, uint256 twJTYieldShareAccruedWAD);

    /**
     * @notice Emitted when LT's share of ST yield (the liquidity premium) is accrued based on the market's liquidityUtilization since the last accrual
     * @param ltYieldShareWAD LT's instantaneous yield share (LT YDM output) based on liquidityUtilization since the last accrual
     * @param twLTYieldShareAccruedWAD The time-weighted LT yield share accrued since the last liquidity premium payment
     */
    event LiquidityTrancheYieldShareAccrued(uint256 ltYieldShareWAD, uint256 twLTYieldShareAccruedWAD);

    /// @notice Emitted when a fixed term regime is commenced by this market
    /// @param fixedTermEndTimestamp The end timestamp of the new fixed term regime
    event FixedTermCommenced(uint32 fixedTermEndTimestamp);

    /// @notice Emitted when a pre or post operation tranche accounting synchronization is executed
    /// @param resultingState The resulting market state after synchronizing the tranche accounting
    event TrancheAccountingSynced(SyncedAccountingState resultingState);

    /// @notice Emitted when the kernel commits the liquidity tranche's freshly marked raw NAV after a sync
    /// @param ltRawNAV The committed liquidity tranche raw NAV (the oracle value of the AMM or another market-making venue)
    event LiquidityTrancheRawNAVCommitted(NAV_UNIT ltRawNAV);

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

    /// @notice Emitted when the yield share (liquidity premium) protocol fee percentage is updated
    /// @param ltYieldShareProtocolFeeWAD The new protocol fee percentage charged from the yield share (liquidity premium) payed from the senior tranche yield to the liquidity tranche, scaled to WAD precision
    event LiquidityTrancheYieldShareProtocolFeeUpdated(uint64 ltYieldShareProtocolFeeWAD);

    /// @notice Emitted when the liquidity percentage requirement is updated
    /// @param minLiquidityWAD The new percentage of the senior tranche NAV that must be in the liquidity tranche's market making inventory, scaled to WAD precision
    event LiquidityUpdated(uint64 minLiquidityWAD);

    /// @notice Emitted when the maximum JT and LT yield shares (premiums) are updated
    /// @param maxJTYieldShareWAD The new maximum JT yield share (risk premium) as a percentage of senior appreciation, scaled to WAD precision
    /// @param maxLTYieldShareWAD The new maximum LT yield share (liquidity premium) as a percentage of senior appreciation, scaled to WAD precision
    event MaxYieldSharesUpdated(uint64 maxJTYieldShareWAD, uint64 maxLTYieldShareWAD);

    /// @notice Thrown when the caller of the function is not the accountant's configured Royco Kernel
    error ONLY_ROYCO_KERNEL();

    /// @notice Thrown when the accountant's coverage configuration is invalid (can be due to incorrect coverage or liquidation coverageUtilization values)
    error INVALID_COVERAGE_CONFIG();

    /// @notice Thrown when the accountant's liquidity configuration is invalid (the minimum liquidity must be less than 100%)
    error INVALID_LIQUIDITY_CONFIG();

    /// @notice Thrown when the accountant's yield share configuration is invalid (the maximum JT and LT yield shares must sum to at most 100%)
    error INVALID_MAX_YIELD_SHARE_CONFIG();

    /// @notice Thrown when the configured protocol fee exceeds the maximum
    error MAX_PROTOCOL_FEE_EXCEEDED();

    /// @notice Thrown when the junior and liquidity tranche YDMs are identical
    error YDMS_CANNOT_BE_IDENTICAL();

    /// @notice Thrown when the YDM failed to initialize
    /// @param data The return data of the reverting YDM initialization
    error FAILED_TO_INITIALIZE_YDM(bytes data);

    /// @notice Thrown when the sum of the raw NAVs don't equal the sum of the effective NAVs of both tranches
    error NAV_CONSERVATION_VIOLATION();

    /// @notice Thrown when the combined risk and liquidity premiums exceed the senior gain they are drawn from: the JT and LT yield shares must sum to at most 100% of senior appreciation
    error PREMIUMS_EXCEED_SENIOR_YIELD();

    /// @notice Thrown when the operation and NAVs passed to post-op lead to an invalid state
    error INVALID_POST_OP_STATE(Operation _op);

    /// @notice Thrown when the market's coverage requirement is violated
    error COVERAGE_REQUIREMENT_VIOLATED();

    /// @notice Thrown when the market's liquidity requirement is violated
    error LIQUIDITY_REQUIREMENT_VIOLATED();

    /// @notice Retrieves the address of the kernel tied to this accountant
    /// @return kernel The kernel that this accountant maintains mark-to-market NAV, JT coverage impermanent loss, and fee accounting for
    function KERNEL() external view returns (address kernel);

    /// @notice Whether the junior tranche is co-invested in the same yield-bearing opportunity as senior (shares senior's downside stress) or in a risk-free opportunity (cash, TBILLs, Aave Core, etc.) with respect to NAV units
    /// @return jtCoinvested True if the junior tranche is co-invested with the senior tranche, false if it is in a risk-free opportunity
    function JT_COINVESTED() external view returns (bool jtCoinvested);

    /**
     * @notice Synchronizes the effective NAVs and impermanent losses of both tranches by marking them to market
     * @dev Must be called before any NAV mutating operation
     * @dev Accrues JT yield share over time based on the market's JT YDM output
     * @dev Persists updated NAV and impermanent loss checkpoints for the next sync to use as reference
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @dev The returned state's ltRawNAV and liquidityUtilizationWAD are zero placeholders: this sync does not mark the liquidity
     *      tranche. The kernel commits the freshly marked liquidity tranche raw NAV via commitLiquidityTrancheRawNAV after minting the
     *      fee shares, then refreshes both fields in the state packet in memory
     */
    function preOpSyncTrancheAccounting(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) external returns (SyncedAccountingState memory state);

    /**
     * @notice Previews a synchronization of the effective NAVs and impermanent losses of both tranches by marking them to market
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @dev The returned state's ltRawNAV and liquidityUtilizationWAD are zero placeholders (this sync does not mark the liquidity tranche); the kernel preview refreshes them in memory
     */
    function previewSyncTrancheAccounting(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) external view returns (SyncedAccountingState memory state);

    /**
     * @notice Applies post-operation (deposit or redemption) raw NAV deltas to effective NAV checkpoints, commits the liquidity tranche's fresh raw NAV, and optionally enforces the market requirement(s) the operation can worsen
     * @dev Strictly interprets NAV deltas as deposits/redemptions instead of PNL
     * @dev Unlike the pre-op sync, the post-op sync runs no waterfall and pays no premium, so it can commit the liquidity tranche raw NAV
     *      directly (the kernel marks it after the operation's pool mutation has settled) and report the resulting liquidity utilization
     * @dev When enforcement is requested, fails fast on the coverage requirement for operations that can worsen coverage (add senior exposure or
     *      remove the junior loss-absorption buffer: ST_DEPOSIT, LT_DEPOSIT, JT_REDEEM) and on the liquidity requirement for operations that can
     *      worsen liquidity (raise the senior effective NAV or reduce the depth of the AMM or another market-making venue: ST_DEPOSIT, the multi-asset
     *      LT_DEPOSIT, and an LT_REDEEM that pays no self-liquidation bonus). A bonus-paying LT_REDEEM is a liquidation-breach exit and is exempt; bypass
     *      redemptions and intermediate multi-asset sub-syncs pass false, deferring enforcement to the final post-op sync that books the combined exposure
     * @param _op The operation being executed in between the pre and post operation synchronizations
     * @param _stRawNAV The post-op senior tranche's raw NAV
     * @param _jtRawNAV The post-op junior tranche's raw NAV
     * @param _ltRawNAV The post-op liquidity tranche's freshly marked raw NAV (the oracle value of the AMM or another market-making venue), committed by this call
     * @param _stSelfLiquidationBonusNAV The self-liquidation bonus remitted to an ST LP on redemption after the liquidation coverageUtilization threshold has been breached, sourced from JT effective NAV
     * @param _enforceCoverageAndLiquidityRequirements Whether to enforce the market's coverage and liquidity requirements applicable to the operation
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function postOpSyncTrancheAccounting(
        Operation _op,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV,
        NAV_UNIT _stSelfLiquidationBonusNAV,
        bool _enforceCoverageAndLiquidityRequirements
    )
        external
        returns (SyncedAccountingState memory state);

    /**
     * @notice Commits the liquidity tranche's freshly marked raw NAV
     * @dev MUST be called by the kernel only after preOpSyncTrancheAccounting has committed the senior/junior NAVs AND the resulting
     *      premium and protocol fee shares have been minted. This ordering is required for correctness: the fresh mark is read from the
     *      AMM or another market-making venue oracle, whose senior leg is rate-scaled by the senior share rate (committed senior effective NAV over senior supply), so
     *      only after the pre-op sync and its share mints does the mark reflect the final post-sync, post-mint senior state. Committing
     *      it out of this order records a liquidity tranche raw NAV against a stale senior state
     * @dev Committing the liquidity tranche raw NAV here, separately from the pre-op waterfall, is what keeps it out of the P&L
     *      attribution and out of the senior share rate provider's dependency loop; the kernel derives the resulting liquidity
     *      utilization from this mark and the synced senior effective NAV it already holds, avoiding an extra storage read
     * @param _freshLtRawNAV The liquidity tranche's freshly marked raw NAV (the oracle value of the AMM or another market-making venue)
     */
    function commitLiquidityTrancheRawNAV(NAV_UNIT _freshLtRawNAV) external;

    /**
     * @notice Returns the maximum assets depositable into the senior tranche without violating the market's coverage or liquidity requirements
     * @dev Always rounds in favor of senior tranche protection
     * @param state The synced accounting state that the maximum senior deposit is computed against
     * @return maxDepositableNAV The maximum assets depositable into the senior tranche without violating the market's coverage or liquidity requirements
     */
    function maxSTDeposit(SyncedAccountingState memory state) external view returns (NAV_UNIT maxDepositableNAV);

    /**
     * @notice Returns the maximum assets withdrawable from the junior tranche without violating the market's coverage requirement
     * @dev Always rounds in favor of senior tranche protection
     * @param state The synced accounting state that the maximum junior withdrawal is computed against
     * @return stWithdrawableNAV The maximum claims on ST assets that the junior tranche can withdraw, denominated in NAV units
     * @return jtWithdrawableNAV The maximum claims on JT assets that the junior tranche can withdraw, denominated in NAV units
     */
    function maxJTWithdrawal(SyncedAccountingState memory state) external view returns (NAV_UNIT stWithdrawableNAV, NAV_UNIT jtWithdrawableNAV);

    /**
     * @notice Returns the maximum assets withdrawable from the liquidity tranche without violating the market's liquidity requirement
     * @dev Always rounds in favor of senior tranche protection
     * @param state The synced accounting state that the maximum liquidity withdrawal is computed against
     * @return ltWithdrawableNAV The maximum market-making depth that the liquidity tranche can withdraw, denominated in NAV units
     */
    function maxLTWithdrawal(SyncedAccountingState memory state) external view returns (NAV_UNIT ltWithdrawableNAV);

    /**
     * @notice Updates the JT YDM (Junior Tranche Yield Distribution Model) for this market
     * @dev Only callable by a designated admin
     * @param _jtYDM The new JT YDM address to set
     * @param _jtYDMInitializationData The data used to initialize the new JT YDM for this market
     */
    function setJuniorTrancheYDM(address _jtYDM, bytes calldata _jtYDMInitializationData) external;

    /**
     * @notice Updates the LT YDM (Liquidity Tranche Yield Distribution Model) for this market
     * @dev Only callable by a designated admin
     * @param _ltYDM The new LT YDM address to set
     * @param _ltYDMInitializationData The data used to initialize the new LT YDM for this market
     */
    function setLiquidityTrancheYDM(address _ltYDM, bytes calldata _ltYDMInitializationData) external;

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
     * @notice Updates the yield share (liquidity premium) protocol fee percentage for this market
     * @dev Only callable by a designated admin
     * @param _ltYieldShareProtocolFeeWAD The new protocol fee percentage charged on the yield share (liquidity premium) payed from senior tranche yield to the liquidity tranche, scaled to WAD precision
     */
    function setLTYieldShareProtocolFee(uint64 _ltYieldShareProtocolFeeWAD) external;

    /**
     * @notice Updates the minimum coverage requirement for this market
     * @dev Only callable by a designated admin
     * @param _minCoverageWAD The new coverage percentage, scaled to WAD precision
     */
    function setMinCoverage(uint64 _minCoverageWAD) external;

    /**
     * @notice Updates the liquidation coverageUtilization threshold for this market
     * @dev Only callable by a designated admin
     * @param _liquidationCoverageUtilizationWAD The new liquidation coverageUtilization threshold for this market, scaled to WAD precision
     */
    function setLiquidationCoverageUtilization(uint256 _liquidationCoverageUtilizationWAD) external;

    /**
     * @notice Updates the minimum liquidity requirement for this market
     * @dev Only callable by a designated admin
     * @param _minLiquidityWAD The new percentage of the senior tranche NAV that must be in the liquidity tranche's market making inventory, scaled to WAD precision
     */
    function setMinLiquidity(uint64 _minLiquidityWAD) external;

    /**
     * @notice Updates the maximum JT and LT yield shares (premiums) for this market
     * @dev Only callable by a designated admin
     * @param _maxJTYieldShareWAD The new maximum JT yield share (risk premium) as a percentage of senior appreciation, scaled to WAD precision
     * @param _maxLTYieldShareWAD The new maximum LT yield share (liquidity premium) as a percentage of senior appreciation, scaled to WAD precision
     */
    function setMaxYieldShares(uint64 _maxJTYieldShareWAD, uint64 _maxLTYieldShareWAD) external;

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
    function getState() external view returns (RoycoDayAccountantState memory state);

    /**
     * @notice Returns the senior tranche's last committed effective NAV from the accounting checkpoint
     * @dev A narrow read for hot-path consumers (the senior share rate provider) that avoids copying the full accountant state struct
     * @return lastSTEffectiveNAV The senior tranche's last committed effective NAV
     */
    function getLastSTEffectiveNAV() external view returns (NAV_UNIT lastSTEffectiveNAV);
}
