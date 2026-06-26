// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoDayAccountant } from "../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { IYDM } from "../interfaces/IYDM.sol";
import { AccountingLib } from "../libraries/AccountingLib.sol";
import { MAX_NAV_UNITS, MAX_PROTOCOL_FEE_WAD, WAD, ZERO_NAV_UNITS } from "../libraries/Constants.sol";
import {
    AccountingCheckpoint,
    MarketState,
    MarketStateTransitionParams,
    NAV_UNIT,
    Operation,
    PnLWaterfallParams,
    SyncedAccountingState
} from "../libraries/Types.sol";
import { UnitsMathLib, toNAVUnits } from "../libraries/Units.sol";
import { Math, UtilsLib } from "../libraries/UtilsLib.sol";

/**
 * @title RoycoDayAccountant
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Performs and tracks the accounting, coverage, and liquidity operations and requirements for a Royco market
 * @notice Responsible for marking tranche NAVs to market, tracking the JT coverage impermanent loss, distributing yield via the JT and LT YDM, and computing protocol fees
 */
contract RoycoDayAccountant is IRoycoDayAccountant, RoycoBase {
    using Math for uint256;
    using UnitsMathLib for NAV_UNIT;

    /// @dev Storage slot for RoycoDayAccountantState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoDayAccountantState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_DAY_ACCOUNTANT_STORAGE_SLOT = 0x3eb9440b0208b8d20dc454b361ed9d3f272aa9a4fb2bcc89d823d3b8e5663200;

    /// @inheritdoc IRoycoDayAccountant
    address public immutable override(IRoycoDayAccountant) KERNEL;

    /// @dev Permissions the function to only be callable by the market's kernel
    /// @dev Should be placed on all state mutating NAV synchronization functions
    modifier onlyRoycoKernel() {
        require(msg.sender == KERNEL, ONLY_ROYCO_KERNEL());
        _;
    }

    /// @dev Synchronizes the market's accounting to reconcile unrealized PNL at the start of the call
    modifier withSyncedAccounting() {
        IRoycoDayKernel(KERNEL).syncTrancheAccounting();
        _;
    }

    // =============================
    // Construction and Initialization Functions
    // =============================

    /// @dev Constructs the accountant with the specified kernel
    /// @param _kernel The kernel that this accountant maintains mark-to-market NAV, JT coverage impermanent loss, and fee accounting for
    constructor(address _kernel) {
        // Ensure the specified kernel is not null and immutably set it
        require(_kernel != address(0), NULL_ADDRESS());
        KERNEL = _kernel;
    }

    /**
     * @notice Initializes the Royco accountant state
     * @param _params The initialization parameters for the Royco accountant
     * @param _initialAuthority The initial authority for the Royco accountant
     */
    function initialize(RoycoDayAccountantInitParams calldata _params, address _initialAuthority) external initializer {
        // Initialize the base state of the accountant
        __RoycoBase_init(_initialAuthority);

        // Initialize the accountant state
        // Ensure that the protocol fee percentages are valid
        require(
            _params.stProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD && _params.jtProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD
                && _params.jtYieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD && _params.ltProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD
                && _params.ltYieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD,
            MAX_PROTOCOL_FEE_EXCEEDED()
        );
        // Ensure that the YDMs are not identical
        // Each tranche requires its own YDM instance: the YDMs are initialized per market and the adaptive models keep per-market curve state, so sharing one instance would corrupt both premiums by interleaving coverage and liquidity driven updates
        require(_params.jtYDM != _params.ltYDM, YDMS_CANNOT_BE_IDENTICAL());

        // Validate the market's initial coverage and liquidity configuration
        _validateCoverageConfig(_params.minCoverageWAD, _params.betaWAD, _params.liquidationCoverageUtilizationWAD);
        _validateLiquidityConfig(_params.minLiquidityWAD);
        _validateYieldShareConfig(_params.maxJTYieldShareWAD, _params.maxLTYieldShareWAD);

        // Initialize the JT and LT YDMs for this market
        _initializeYDM(_params.jtYDM, _params.jtYDMInitializationData);
        _initializeYDM(_params.ltYDM, _params.ltYDMInitializationData);

        // Persist the initial accountant state, grouping the writes by storage slot so the packed fields in each slot coalesce into a single store
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Set the fields in slot 0 of storage
        $.stProtocolFeeWAD = _params.stProtocolFeeWAD;
        $.jtProtocolFeeWAD = _params.jtProtocolFeeWAD;
        $.jtYieldShareProtocolFeeWAD = _params.jtYieldShareProtocolFeeWAD;
        $.ltProtocolFeeWAD = _params.ltProtocolFeeWAD;
        emit SeniorTrancheProtocolFeeUpdated(_params.stProtocolFeeWAD);
        emit JuniorTrancheProtocolFeeUpdated(_params.jtProtocolFeeWAD);
        emit JuniorTrancheYieldShareProtocolFeeUpdated(_params.jtYieldShareProtocolFeeWAD);
        emit LiquidityTrancheProtocolFeeUpdated(_params.ltProtocolFeeWAD);

        // Set the fields in slot 1 of storage
        $.ltYieldShareProtocolFeeWAD = _params.ltYieldShareProtocolFeeWAD;
        $.minCoverageWAD = _params.minCoverageWAD;
        $.fixedTermDurationSeconds = _params.fixedTermDurationSeconds;
        emit LiquidityTrancheYieldShareProtocolFeeUpdated(_params.ltYieldShareProtocolFeeWAD);
        emit CoverageUpdated(_params.minCoverageWAD);
        emit FixedTermDurationUpdated(_params.fixedTermDurationSeconds);

        // Set the fields in slot 2 of storage
        $.jtYDM = _params.jtYDM;
        $.betaWAD = _params.betaWAD;
        emit JuniorTrancheYDMUpdated(_params.jtYDM);
        emit BetaUpdated(_params.betaWAD);

        // Set the fields in slot 3 of storage
        $.ltYDM = _params.ltYDM;
        $.minLiquidityWAD = _params.minLiquidityWAD;
        emit LiquidityTrancheYDMUpdated(_params.ltYDM);
        emit LiquidityUpdated(_params.minLiquidityWAD);

        // Set the maximum yield shares in slot 4 and slot 5 of storage (their time-weighted accumulators are zero-initialized)
        $.maxJTYieldShareWAD = _params.maxJTYieldShareWAD;
        $.maxLTYieldShareWAD = _params.maxLTYieldShareWAD;
        emit MaxYieldSharesUpdated(_params.maxJTYieldShareWAD, _params.maxLTYieldShareWAD);

        // Set the rest of the fields
        $.liquidationCoverageUtilizationWAD = _params.liquidationCoverageUtilizationWAD;
        $.stNAVDustTolerance = _params.stNAVDustTolerance;
        $.jtNAVDustTolerance = _params.jtNAVDustTolerance;
        $.effectiveNAVDustTolerance = _params.stNAVDustTolerance + _params.jtNAVDustTolerance;
        $.ltNAVDustTolerance = _params.ltNAVDustTolerance;
        emit LiquidationCoverageUtilizationUpdated(_params.liquidationCoverageUtilizationWAD);
        emit SeniorTrancheDustToleranceUpdated(_params.stNAVDustTolerance);
        emit JuniorTrancheDustToleranceUpdated(_params.jtNAVDustTolerance);
        emit LiquidityTrancheDustToleranceUpdated(_params.ltNAVDustTolerance);
    }

    // =============================
    // NAV Synchronization Functions
    // =============================

    /// @inheritdoc IRoycoDayAccountant
    function preOpSyncTrancheAccounting(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV
    )
        public
        override(IRoycoDayAccountant)
        onlyRoycoKernel
        returns (SyncedAccountingState memory state)
    {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Accrue the JT and LT yield shares, then preview the synchronization of the tranche NAVs and the JT coverage impermanent loss
        MarketState initialMarketState;
        bool premiumsPaid;
        NAV_UNIT jtCoverageImpermanentLossErased;
        (uint192 twJTYieldShareAccruedWAD, uint192 twLTYieldShareAccruedWAD) = _accruePremiumYieldShares();
        (state, initialMarketState, premiumsPaid, jtCoverageImpermanentLossErased) =
            _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _ltRawNAV, twJTYieldShareAccruedWAD, twLTYieldShareAccruedWAD);

        // The JT risk and LT liquidity premiums were paid out of ST yield
        if (premiumsPaid) {
            // Reset the accumulators and update the last premium payment timestamp
            delete $.twJTYieldShareAccruedWAD;
            delete $.twLTYieldShareAccruedWAD;
            $.lastPremiumPaymentTimestamp = uint32(block.timestamp);
        }

        // Checkpoint the resulting market state, mark-to-market NAVs, and the JT coverage impermanent loss
        $.lastMarketState = state.marketState;
        $.lastSTRawNAV = _stRawNAV;
        $.lastJTRawNAV = _jtRawNAV;
        $.lastLTRawNAV = _ltRawNAV;
        $.lastSTEffectiveNAV = state.stEffectiveNAV;
        $.lastJTEffectiveNAV = state.jtEffectiveNAV;
        $.lastJTCoverageImpermanentLoss = state.jtCoverageImpermanentLoss;

        // If the market transitioned from a perpetual to a fixed-term state, set the end timestamp of the fixed-term
        if (initialMarketState == MarketState.PERPETUAL && state.marketState == MarketState.FIXED_TERM) {
            emit FixedTermCommenced(($.fixedTermEndTimestamp = state.fixedTermEndTimestamp));
        } else if (initialMarketState == MarketState.FIXED_TERM && state.marketState == MarketState.PERPETUAL) {
            emit FixedTermEnded();
        }

        // If the JT Coverage IL was erased, signal the resetting
        if (jtCoverageImpermanentLossErased != ZERO_NAV_UNITS) emit JuniorTrancheCoverageImpermanentLossReset(jtCoverageImpermanentLossErased);

        emit TrancheAccountingSynced(state);
    }

    /// @inheritdoc IRoycoDayAccountant
    function previewSyncTrancheAccounting(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV
    )
        public
        view
        override(IRoycoDayAccountant)
        returns (SyncedAccountingState memory state)
    {
        (uint192 twJTYieldShareAccruedWAD, uint192 twLTYieldShareAccruedWAD) = _previewPremiumYieldShareAccrual();
        (state,,,) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _ltRawNAV, twJTYieldShareAccruedWAD, twLTYieldShareAccruedWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function postOpSyncTrancheAccounting(
        Operation _op,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV,
        NAV_UNIT _stSelfLiquidationBonusNAV
    )
        public
        override(IRoycoDayAccountant)
        onlyRoycoKernel
        returns (SyncedAccountingState memory state)
    {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Compute the deltas in the raw NAVs of each tranche
        int256 deltaSTRawNAV = UnitsMathLib.computeNAVDelta(_stRawNAV, $.lastSTRawNAV);
        int256 deltaJTRawNAV = UnitsMathLib.computeNAVDelta(_jtRawNAV, $.lastJTRawNAV);

        // Cache the last checkpointed NAVs and the JT coverage impermanent loss
        NAV_UNIT stEffectiveNAV = $.lastSTEffectiveNAV;
        NAV_UNIT jtEffectiveNAV = $.lastJTEffectiveNAV;
        NAV_UNIT jtCoverageImpermanentLoss = $.lastJTCoverageImpermanentLoss;

        // Apply the effects of the operation that was executed
        if (_op == Operation.ST_DEPOSIT) {
            require(deltaSTRawNAV > 0 && deltaJTRawNAV == 0 && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
            // New ST deposits are treated as an addition to the future ST exposure
            stEffectiveNAV = stEffectiveNAV + toNAVUnits(deltaSTRawNAV);
        } else if (_op == Operation.JT_DEPOSIT) {
            require(deltaJTRawNAV > 0 && deltaSTRawNAV == 0 && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
            // New JT deposits are treated as an addition to the future loss-absorption buffer
            jtEffectiveNAV = jtEffectiveNAV + toNAVUnits(deltaJTRawNAV);
        } else {
            require(deltaSTRawNAV <= 0 && deltaJTRawNAV <= 0, INVALID_POST_OP_STATE(_op));
            // Get the total value redeemed
            NAV_UNIT totalRedemptionNAV = (toNAVUnits(-deltaSTRawNAV) + toNAVUnits(-deltaJTRawNAV));
            if (_op == Operation.ST_REDEEM) {
                require(totalRedemptionNAV > ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
                // Reduce JT effective NAV by the the bonus provided from its assets
                jtEffectiveNAV = jtEffectiveNAV - _stSelfLiquidationBonusNAV;
                // Reduce ST effective NAV by the total redemptions without the bonus provided from JT effective NAV
                stEffectiveNAV = stEffectiveNAV - (totalRedemptionNAV - _stSelfLiquidationBonusNAV);
            } else if (_op == Operation.JT_REDEEM) {
                // JT cannot get a bonus from its own NAV
                require(totalRedemptionNAV > ZERO_NAV_UNITS && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
                // The actual amount withdrawn from JT effective NAV could be from both tranches (its own share of its NAV, ST yield share, IL repayments, etc.)
                jtEffectiveNAV = jtEffectiveNAV - totalRedemptionNAV;
                // The withdrawing junior LP has realized its proportional share of past JT losses from coverage applied and its associated recovery optionality, rounding in favor of senior
                if (jtCoverageImpermanentLoss != ZERO_NAV_UNITS) {
                    jtCoverageImpermanentLoss = jtCoverageImpermanentLoss.mulDiv(jtEffectiveNAV, $.lastJTEffectiveNAV, Math.Rounding.Floor);
                    $.lastJTCoverageImpermanentLoss = jtCoverageImpermanentLoss;
                }
            }
        }

        // Enforce the NAV conservation invariant
        AccountingLib.enforceNAVConservation(_stRawNAV, _jtRawNAV, stEffectiveNAV, jtEffectiveNAV);

        // Checkpoint the mark-to-market NAVs
        $.lastSTRawNAV = _stRawNAV;
        $.lastJTRawNAV = _jtRawNAV;
        $.lastLTRawNAV = _ltRawNAV;
        $.lastSTEffectiveNAV = stEffectiveNAV;
        $.lastJTEffectiveNAV = jtEffectiveNAV;

        // Marshal the post-sync state and return to the caller
        uint256 betaWAD = $.betaWAD;
        uint256 minCoverageWAD = $.minCoverageWAD;
        uint256 minLiquidityWAD = $.minLiquidityWAD;
        state = SyncedAccountingState({
            // The market state is guaranteed to be identical to the persisted
            marketState: $.lastMarketState,
            stRawNAV: _stRawNAV,
            jtRawNAV: _jtRawNAV,
            ltRawNAV: ZERO_NAV_UNITS, // TODO: Implement LT raw NAV
            stEffectiveNAV: stEffectiveNAV,
            jtEffectiveNAV: jtEffectiveNAV,
            jtCoverageImpermanentLoss: jtCoverageImpermanentLoss,
            // No liquidity premium accrued on deposit or withdrawal: the premium is only paid on senior yield
            ltLiquidityPremium: ZERO_NAV_UNITS,
            // No protocol fees taken on deposit or withdrawal
            stProtocolFee: ZERO_NAV_UNITS,
            jtProtocolFee: ZERO_NAV_UNITS,
            ltProtocolFee: ZERO_NAV_UNITS,
            coverageUtilizationWAD: UtilsLib.computeCoverageUtilization(_stRawNAV, _jtRawNAV, betaWAD, minCoverageWAD, jtEffectiveNAV),
            liquidityUtilizationWAD: UtilsLib.computeLiquidityUtilization(stEffectiveNAV, minLiquidityWAD, _ltRawNAV),
            fixedTermEndTimestamp: $.fixedTermEndTimestamp,
            minCoverageWAD: minCoverageWAD,
            betaWAD: betaWAD,
            liquidationCoverageUtilizationWAD: $.liquidationCoverageUtilizationWAD,
            minLiquidityWAD: minLiquidityWAD
        });
    }

    /// @inheritdoc IRoycoDayAccountant
    function postOpSyncTrancheAccountingAndEnforceCoverage(
        Operation _op,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV
    )
        external
        override(IRoycoDayAccountant)
        returns (SyncedAccountingState memory state)
    {
        // Execute a post-op NAV synchronization
        // This is called during a ST Deposit or JT Withdrawal, so the self-liquidation bonus is not applicable
        state = postOpSyncTrancheAccounting(_op, _stRawNAV, _jtRawNAV, _ltRawNAV, ZERO_NAV_UNITS);
        // Enforce the market's coverage requirement
        require((state.coverageUtilizationWAD <= WAD), COVERAGE_REQUIREMENT_UNSATISFIED());
    }

    // =============================
    // Coverage and Liquidity Checking Functions
    // =============================

    /**
     * @inheritdoc IRoycoDayAccountant
     * @dev ST deposits are bounded by the current coverage and liquidity requirements of the market
     *
     * @dev Coverage Requirement: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * β)) * MIN_COVERAGE
     * @dev Max assets depositable into ST, x: JT_EFFECTIVE_NAV = ((ST_RAW_NAV + x) + (JT_RAW_NAV * β)) * MIN_COVERAGE
     *      Isolate x: x = (JT_EFFECTIVE_NAV / MIN_COVERAGE) - (JT_RAW_NAV * β) - ST_RAW_NAV
     *
     * @dev Liquidity Requirement: LT_RAW_NAV >= (ST_EFFECTIVE_NAV * MIN_LIQUIDITY)
     * @dev Max assets depositable into ST, y: LT_RAW_NAV = (ST_EFFECTIVE_NAV + y) * MIN_LIQUIDITY
     *      Isolate y: y = (LT_RAW_NAV / MIN_LIQUIDITY) - ST_EFFECTIVE_NAV
     *
     * @dev The maximum deposit is the minimum of x and y
     */
    function maxSTDeposit(SyncedAccountingState memory state) external view override(IRoycoDayAccountant) returns (NAV_UNIT) {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Compute the max ST deposit given the coverage requirement
        // If there is no minimum coverage requirement, there is no ST capacity restriction
        NAV_UNIT maxSTDepositGivenCoverage = MAX_NAV_UNITS;
        if (state.minCoverageWAD != 0) {
            // Solve for x, rounding in favor of senior protection
            // Compute the total covered assets by the junior tranche loss absorption buffer
            NAV_UNIT totalCoveredAssets = state.jtEffectiveNAV.mulDiv(WAD, state.minCoverageWAD, Math.Rounding.Floor);
            // Compute the assets required to cover current junior tranche exposure
            // Also account for JT's dust tolerance to preclude reverts due to rounding after ST deposit (if both are exposed to the same underlying rounding)
            NAV_UNIT jtCoverageRequired = state.jtRawNAV.mulDiv(state.betaWAD, WAD, Math.Rounding.Ceil) + $.jtNAVDustTolerance;
            // Compute the value of assets that can be deposited into senior while retaining minimum coverage
            // Also account for ST's dust tolerance to preclude reverts due to rounding after ST deposit
            maxSTDepositGivenCoverage = totalCoveredAssets.saturatingSub((jtCoverageRequired + state.stRawNAV + $.stNAVDustTolerance));
        }

        //  Compute the max ST deposit given the liquidity requirement
        // If there is no minimum liquidity requirement, there is no ST capacity restriction
        NAV_UNIT maxSTDepositGivenLiquidity = MAX_NAV_UNITS;
        if (state.minLiquidityWAD != 0) {
            // Solve for y, rounding in favor of senior protection
            // Compute the maximum value ownable by the senior tranche given the current value of the market making inventory
            // Also account for LT's dust tolerance to preclude reverts due to rounding after ST deposit
            NAV_UNIT maxSTEffectiveNAV = (state.ltRawNAV.saturatingSub($.ltNAVDustTolerance)).mulDiv(WAD, state.minLiquidityWAD, Math.Rounding.Floor);
            // Compute the value of assets that can be deposited into senior while retaining minimum liquidity
            // Also account for ST's dust tolerance to preclude reverts due to rounding after ST deposit
            maxSTDepositGivenLiquidity = maxSTEffectiveNAV.saturatingSub(state.stEffectiveNAV + $.stNAVDustTolerance);
        }

        // The maximum deposit is the minimum of x and y
        return UnitsMathLib.min(maxSTDepositGivenCoverage, maxSTDepositGivenLiquidity);
    }

    /**
     * @inheritdoc IRoycoDayAccountant
     * @dev Coverage Requirement: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * β)) * MIN_COVERAGE
     * @dev When assets are claimed from the JT, they are always liquidated in the same proportion as the tranche's total claims on the ST and JT assets
     * @dev Let S be the JT's total claims on ST assets and J be the JT's total claims on JT assets, in NAV Units. The total claims on the ST and JT assets are S + J NAV Units
     * @dev Let K_S be S / (S + J) and K_J be J / (S + J)
     * @dev Therefore, if a total NAV of z is claimed from the JT, K_S * z will be claimed from the ST_RAW_NAV and K_J * z will be claimed from the JT_RAW_NAV
     * @dev Max assets withdrawable from JT, z: (JT_EFFECTIVE_NAV - z) = ((ST_RAW_NAV - K_S * z) + ((JT_RAW_NAV - K_J * z) * β)) * COV
     *      Isolate z: z = (JT_EFFECTIVE_NAV - (MIN_COVERAGE * (ST_RAW_NAV + (JT_RAW_NAV * β)))) / (1 - (MIN_COVERAGE * (K_S + β * K_J)))
     */
    function maxJTWithdrawal(SyncedAccountingState memory state)
        external
        view
        override(IRoycoDayAccountant)
        returns (NAV_UNIT totalNAVClaimable, NAV_UNIT stClaimable, NAV_UNIT jtClaimable)
    {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Decompose the junior tranche's claims on the ST and JT raw NAVs from the synced accounting state
        (,, NAV_UNIT jtClaimOnStUnits, NAV_UNIT jtClaimOnJtUnits) = UtilsLib.computeTrancheClaimsOnNAVs(state);

        // Get the surplus JT assets in NAV units
        // Compute the total covered exposure of the underlying investment, rounding in favor of senior protection
        NAV_UNIT totalCoveredExposure = state.stRawNAV + state.jtRawNAV.mulDiv(state.betaWAD, WAD, Math.Rounding.Ceil);
        // Compute the minimum junior tranche assets required to cover the exposure as per the market's coverage requirement
        NAV_UNIT requiredJTAssets = totalCoveredExposure.mulDiv(state.minCoverageWAD, WAD, Math.Rounding.Ceil);
        // Compute the surplus coverage currently provided by the junior tranche based on its currently remaining loss-absorption buffer
        // Also account for the effective dust tolerance required to preclude reverts due to rounding after JT redemptions
        NAV_UNIT surplusJTAssets = state.jtEffectiveNAV.saturatingSub(requiredJTAssets)
            .saturatingSub($.stNAVDustTolerance + $.jtNAVDustTolerance.mulDiv(state.betaWAD, WAD, Math.Rounding.Ceil)).
            // Additionally absorb the worst case inner-ceil rounding in the coverageUtilization computation
            saturatingSub(toNAVUnits(uint256(2)));
        if (surplusJTAssets == ZERO_NAV_UNITS) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS);

        // Compute the total JT claim on NAV and preemptively return if zero
        NAV_UNIT totalJTClaims = jtClaimOnStUnits + jtClaimOnJtUnits;
        if (totalJTClaims == ZERO_NAV_UNITS) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        // Calculate K_S
        uint256 kS_WAD = jtClaimOnStUnits.mulDiv(WAD, totalJTClaims, Math.Rounding.Floor);
        // Calculate K_J
        uint256 kJ_WAD = jtClaimOnJtUnits.mulDiv(WAD, totalJTClaims, Math.Rounding.Floor);
        // Compute how much coverage the system retains per 1 nav unit of JT assets withdrawn scaled to WAD precision
        uint256 coverageRetentionWAD =
            (WAD - state.minCoverageWAD.mulDiv((kS_WAD + state.betaWAD.mulDiv(kJ_WAD, WAD, Math.Rounding.Floor)), WAD, Math.Rounding.Floor));
        // Calculate how much of the surplus can be withdrawn while satisfying the coverage requirement
        totalNAVClaimable = surplusJTAssets.mulDiv(WAD, coverageRetentionWAD, Math.Rounding.Floor);
        if (totalNAVClaimable == ZERO_NAV_UNITS) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS);

        // Split it into individual tranche's claims
        stClaimable = totalNAVClaimable.mulDiv(kS_WAD, WAD, Math.Rounding.Floor);
        jtClaimable = totalNAVClaimable.mulDiv(kJ_WAD, WAD, Math.Rounding.Floor);
    }

    // =============================
    // Internal NAV Synchronization and Yield Share Accrual Functions
    // =============================

    /**
     * @notice Synchronizes all tranche NAVs and the JT coverage impermanent loss based on unrealized PNLs of the underlying investment(s)
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _ltRawNAV The liquidity tranche's current raw NAV: the pure value of its invested assets
     * @param _twJTYieldShareAccruedWAD The currently accrued time-weighted JT yield share (JT YDM output) since the last premium payment, scaled to WAD precision
     * @param _twLTYieldShareAccruedWAD The currently accrued time-weighted LT yield share (LT YDM output) since the last premium payment, scaled to WAD precision
     * @return state A struct containing all mark-to-market NAV, JT coverage impermanent loss, LT liquidity premium, and fee data after executing the sync
     * @return initialMarketState The initial state the market was in before the synchronization
     * @return premiumsPaid A boolean indicating whether the JT risk and LT liquidity premiums were paid out of ST yield
     * @return jtCoverageImpermanentLossErased The amount of JT coverage loss erased (reset to 0)
     */
    function _previewSyncTrancheAccounting(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV,
        uint192 _twJTYieldShareAccruedWAD,
        uint192 _twLTYieldShareAccruedWAD
    )
        internal
        view
        returns (SyncedAccountingState memory state, MarketState initialMarketState, bool premiumsPaid, NAV_UNIT jtCoverageImpermanentLossErased)
    {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // The market state that this sync transitions from
        initialMarketState = $.lastMarketState;

        // Build the last committed checkpoint from persisted state for the waterfall to settle against
        AccountingCheckpoint memory checkpoint = AccountingCheckpoint({
            stRawNAV: $.lastSTRawNAV,
            jtRawNAV: $.lastJTRawNAV,
            ltRawNAV: $.lastLTRawNAV,
            stEffectiveNAV: $.lastSTEffectiveNAV,
            jtEffectiveNAV: $.lastJTEffectiveNAV,
            jtCoverageImpermanentLoss: $.lastJTCoverageImpermanentLoss
        });

        // The risk and liquidity premiums are always paid together, so they share a single elapsed window since the last premium payment
        uint256 elapsedSinceLastPremiumPayments = block.timestamp - $.lastPremiumPaymentTimestamp;
        // The instantaneous shares are only consumed when the last premium payment happened in the same block, so they are fetched lazily and each capped at its configured maximum
        uint256 instantaneousJTYieldShareWAD;
        uint256 instantaneousLTYieldShareWAD;
        if (elapsedSinceLastPremiumPayments == 0) {
            // The JT YDM is driven by the market's coverage utilization: the JT risk premium scales with how utilized the JT coverage buffer is
            instantaneousJTYieldShareWAD = Math.min(
                IYDM($.jtYDM)
                    .previewYieldShare(
                        initialMarketState,
                        UtilsLib.computeCoverageUtilization($.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.minCoverageWAD, $.lastJTEffectiveNAV)
                    ),
                $.maxJTYieldShareWAD
            );
            // The LT YDM is driven by the market's liquidity utilization: the LT liquidity premium scales with how utilized the LT market-making inventory is
            instantaneousLTYieldShareWAD = Math.min(
                IYDM($.ltYDM)
                    .previewYieldShare(initialMarketState, UtilsLib.computeLiquidityUtilization($.lastSTEffectiveNAV, $.minLiquidityWAD, $.lastLTRawNAV)),
                $.maxLTYieldShareWAD
            );
        }

        // Cache the effective NAV dust tolerance: the worst-case dust is bounded by the sum of the raw NAV dust tolerances
        NAV_UNIT effectiveNAVDustTolerance = $.effectiveNAVDustTolerance;

        // Execute the PnL attribution and settlement waterfall
        NAV_UNIT ltLiquidityPremium;
        NAV_UNIT stProtocolFee;
        NAV_UNIT jtProtocolFee;
        NAV_UNIT ltProtocolFee;
        (checkpoint, ltLiquidityPremium, stProtocolFee, jtProtocolFee, ltProtocolFee, premiumsPaid) = AccountingLib.applyProfitAndLossWaterfall(
            _stRawNAV,
            _jtRawNAV,
            _ltRawNAV,
            PnLWaterfallParams({
                checkpoint: checkpoint,
                twJTYieldShareAccruedWAD: _twJTYieldShareAccruedWAD,
                twLTYieldShareAccruedWAD: _twLTYieldShareAccruedWAD,
                instantaneousJTYieldShareWAD: instantaneousJTYieldShareWAD,
                instantaneousLTYieldShareWAD: instantaneousLTYieldShareWAD,
                elapsedSinceLastPremiumPayments: elapsedSinceLastPremiumPayments,
                stProtocolFeeWAD: $.stProtocolFeeWAD,
                jtProtocolFeeWAD: $.jtProtocolFeeWAD,
                jtYieldShareProtocolFeeWAD: $.jtYieldShareProtocolFeeWAD,
                ltProtocolFeeWAD: $.ltProtocolFeeWAD,
                ltYieldShareProtocolFeeWAD: $.ltYieldShareProtocolFeeWAD,
                effectiveNAVDustTolerance: effectiveNAVDustTolerance,
                ltNAVDustTolerance: $.ltNAVDustTolerance
            })
        );

        // Apply the market state transition resulting from this sync and marshal the post-sync state
        (state, jtCoverageImpermanentLossErased) = AccountingLib.applyStateTransition(
            initialMarketState,
            MarketStateTransitionParams({
                postPnLWaterfallCheckpoint: checkpoint,
                ltLiquidityPremium: ltLiquidityPremium,
                stProtocolFee: stProtocolFee,
                jtProtocolFee: jtProtocolFee,
                ltProtocolFee: ltProtocolFee,
                betaWAD: $.betaWAD,
                minCoverageWAD: $.minCoverageWAD,
                minLiquidityWAD: $.minLiquidityWAD,
                effectiveNAVDustTolerance: effectiveNAVDustTolerance,
                fixedTermDurationSeconds: $.fixedTermDurationSeconds,
                fixedTermEndTimestamp: $.fixedTermEndTimestamp,
                liquidationCoverageUtilizationWAD: $.liquidationCoverageUtilizationWAD,
                currentTimestamp: block.timestamp
            })
        );
    }

    /**
     * @notice Accrues the JT and LT yield shares since the last premium payment
     * @dev Advances the adaptive YDMs and gets the instantaneous yield shares, each capped at its configured maximum, then weights them by the time elapsed since the last accrual
     * @return twJTYieldShareAccruedWAD The updated time-weighted JT yield share since the last premium payment
     * @return twLTYieldShareAccruedWAD The updated time-weighted LT yield share since the last premium payment
     */
    function _accruePremiumYieldShares() internal returns (uint192 twJTYieldShareAccruedWAD, uint192 twLTYieldShareAccruedWAD) {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $.lastYieldShareAccrualTimestamp;
        if (lastUpdate == 0) {
            // Initialize the checkpoint timestamps if this is the first accrual
            $.lastYieldShareAccrualTimestamp = uint32(block.timestamp);
            $.lastPremiumPaymentTimestamp = uint32(block.timestamp);
            return (0, 0);
        }

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return ($.twJTYieldShareAccruedWAD, $.twLTYieldShareAccruedWAD);

        // Advance the adaptive YDMs and read each instantaneous yield share, capped at its configured maximum
        (uint256 coverageUtilizationWAD, uint256 liquidityUtilizationWAD) = _computeUtilizations();
        uint256 jtYieldShareWAD = Math.min(IYDM($.jtYDM).yieldShare($.lastMarketState, coverageUtilizationWAD), $.maxJTYieldShareWAD);
        uint256 ltYieldShareWAD = Math.min(IYDM($.ltYDM).yieldShare($.lastMarketState, liquidityUtilizationWAD), $.maxLTYieldShareWAD);

        // Accrue the time-weighted yield shares since the last tranche interaction
        twJTYieldShareAccruedWAD = ($.twJTYieldShareAccruedWAD += uint192(jtYieldShareWAD * elapsed));
        twLTYieldShareAccruedWAD = ($.twLTYieldShareAccruedWAD += uint192(ltYieldShareWAD * elapsed));
        $.lastYieldShareAccrualTimestamp = uint32(block.timestamp);

        emit JuniorTrancheYieldShareAccrued(jtYieldShareWAD, twJTYieldShareAccruedWAD);
        emit LiquidityTrancheYieldShareAccrued(ltYieldShareWAD, twLTYieldShareAccruedWAD);
    }

    /**
     * @notice Computes and returns the currently accrued JT and LT yield shares since the last premium payment
     * @dev Gets the instantaneous yield shares, each capped at its configured maximum, and weights them by the time elapsed since the last accrual
     * @return twJTYieldShareAccruedWAD The updated time-weighted JT yield share since the last premium payment
     * @return twLTYieldShareAccruedWAD The updated time-weighted LT yield share since the last premium payment
     */
    function _previewPremiumYieldShareAccrual() internal view returns (uint192 twJTYieldShareAccruedWAD, uint192 twLTYieldShareAccruedWAD) {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $.lastYieldShareAccrualTimestamp;
        if (lastUpdate == 0) return (0, 0);

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return ($.twJTYieldShareAccruedWAD, $.twLTYieldShareAccruedWAD);

        // Read each instantaneous yield share, capped at its configured maximum
        (uint256 coverageUtilizationWAD, uint256 liquidityUtilizationWAD) = _computeUtilizations();
        uint256 jtYieldShareWAD = Math.min(IYDM($.jtYDM).previewYieldShare($.lastMarketState, coverageUtilizationWAD), $.maxJTYieldShareWAD);
        uint256 ltYieldShareWAD = Math.min(IYDM($.ltYDM).previewYieldShare($.lastMarketState, liquidityUtilizationWAD), $.maxLTYieldShareWAD);

        // Apply the accrual of the yield shares to the accumulators, weighted by the time elapsed
        twJTYieldShareAccruedWAD = ($.twJTYieldShareAccruedWAD + uint192(jtYieldShareWAD * elapsed));
        twLTYieldShareAccruedWAD = ($.twLTYieldShareAccruedWAD + uint192(ltYieldShareWAD * elapsed));
    }

    /**
     * @notice Computes and returns the coverage and liquidity utilizations
     * @return coverageUtilizationWAD The coverage utilization driving the JT risk premium, scaled to WAD precision
     * @return liquidityUtilizationWAD The liquidity utilization driving the LT liquidity premium, scaled to WAD precision
     */
    function _computeUtilizations() private view returns (uint256 coverageUtilizationWAD, uint256 liquidityUtilizationWAD) {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // Compute both utilizations
        coverageUtilizationWAD = UtilsLib.computeCoverageUtilization($.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.minCoverageWAD, $.lastJTEffectiveNAV);
        liquidityUtilizationWAD = UtilsLib.computeLiquidityUtilization($.lastSTEffectiveNAV, $.minLiquidityWAD, $.lastLTRawNAV);
    }

    // =============================
    // Administrative Functions
    // =============================

    /// @inheritdoc IRoycoDayAccountant
    function setJuniorTrancheYDM(address _jtYDM, bytes calldata _jtYDMInitializationData) external override(IRoycoDayAccountant) restricted {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // The junior and liquidity tranche YDMs must remain distinct: a shared instance would corrupt both premiums by interleaving coverage and liquidity driven updates
        require(_jtYDM != $.ltYDM, YDMS_CANNOT_BE_IDENTICAL());
        // Best-effort sync to settle unrealized PNL under the outgoing JT YDM
        // NOTE: A reverting sync is tolerated since this setter is the only recovery path from a sync-bricking JT YDM
        KERNEL.call(abi.encodeCall(IRoycoDayKernel.syncTrancheAccounting, ()));
        // Initialize and set the new JT YDM for this market
        _initializeYDM(_jtYDM, _jtYDMInitializationData);
        $.jtYDM = _jtYDM;
        emit JuniorTrancheYDMUpdated(_jtYDM);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setLiquidityTrancheYDM(address _ltYDM, bytes calldata _ltYDMInitializationData) external override(IRoycoDayAccountant) restricted {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // The junior and liquidity tranche YDMs must remain distinct: a shared instance would corrupt both premiums by interleaving coverage and liquidity driven updates
        require(_ltYDM != $.jtYDM, YDMS_CANNOT_BE_IDENTICAL());
        // Best-effort sync to settle unrealized PNL under the outgoing LT YDM
        // NOTE: A reverting sync is tolerated since this setter is the only recovery path from a sync-bricking LT YDM
        KERNEL.call(abi.encodeCall(IRoycoDayKernel.syncTrancheAccounting, ()));
        // Initialize and set the new LT YDM for this market
        _initializeYDM(_ltYDM, _ltYDMInitializationData);
        $.ltYDM = _ltYDM;
        emit LiquidityTrancheYDMUpdated(_ltYDM);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setSeniorTrancheProtocolFee(uint64 _stProtocolFeeWAD) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        // Ensure that the protocol fee percentage is valid
        require(_stProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        _getRoycoDayAccountantStorage().stProtocolFeeWAD = _stProtocolFeeWAD;
        emit SeniorTrancheProtocolFeeUpdated(_stProtocolFeeWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setJuniorTrancheProtocolFee(uint64 _jtProtocolFeeWAD) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        // Ensure that the protocol fee percentage is valid
        require(_jtProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        _getRoycoDayAccountantStorage().jtProtocolFeeWAD = _jtProtocolFeeWAD;
        emit JuniorTrancheProtocolFeeUpdated(_jtProtocolFeeWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setLiquidityTrancheProtocolFee(uint64 _ltProtocolFeeWAD) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        // Ensure that the protocol fee percentage is valid
        require(_ltProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        _getRoycoDayAccountantStorage().ltProtocolFeeWAD = _ltProtocolFeeWAD;
        emit LiquidityTrancheProtocolFeeUpdated(_ltProtocolFeeWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setJTYieldShareProtocolFee(uint64 _jtYieldShareProtocolFeeWAD) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        // Ensure that the protocol fee percentage is valid
        require(_jtYieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        _getRoycoDayAccountantStorage().jtYieldShareProtocolFeeWAD = _jtYieldShareProtocolFeeWAD;
        emit JuniorTrancheYieldShareProtocolFeeUpdated(_jtYieldShareProtocolFeeWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setLTYieldShareProtocolFee(uint64 _ltYieldShareProtocolFeeWAD) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        // Ensure that the protocol fee percentage is valid
        require(_ltYieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        _getRoycoDayAccountantStorage().ltYieldShareProtocolFeeWAD = _ltYieldShareProtocolFeeWAD;
        emit LiquidityTrancheYieldShareProtocolFeeUpdated(_ltYieldShareProtocolFeeWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setCoverage(uint64 _minCoverageWAD) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // Validate the new coverage configuration
        _validateCoverageConfig(_minCoverageWAD, $.betaWAD, $.liquidationCoverageUtilizationWAD);
        $.minCoverageWAD = _minCoverageWAD;
        emit CoverageUpdated(_minCoverageWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setBeta(uint96 _betaWAD) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // Validate the new coverage configuration
        _validateCoverageConfig($.minCoverageWAD, _betaWAD, $.liquidationCoverageUtilizationWAD);
        $.betaWAD = _betaWAD;
        emit BetaUpdated(_betaWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setLiquidationCoverageUtilization(uint256 _liquidationCoverageUtilizationWAD)
        external
        override(IRoycoDayAccountant)
        restricted
        withSyncedAccounting
    {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // Validate the new coverage configuration
        _validateCoverageConfig($.minCoverageWAD, $.betaWAD, _liquidationCoverageUtilizationWAD);
        $.liquidationCoverageUtilizationWAD = _liquidationCoverageUtilizationWAD;
        emit LiquidationCoverageUtilizationUpdated(_liquidationCoverageUtilizationWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setCoverageConfiguration(
        uint64 _minCoverageWAD,
        uint96 _betaWAD,
        uint256 _liquidationCoverageUtilizationWAD
    )
        external
        override(IRoycoDayAccountant)
        restricted
        withSyncedAccounting
    {
        // Validate the new coverage configuration
        _validateCoverageConfig(_minCoverageWAD, _betaWAD, _liquidationCoverageUtilizationWAD);
        // Set the new config
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        $.minCoverageWAD = _minCoverageWAD;
        emit CoverageUpdated(_minCoverageWAD);
        $.betaWAD = _betaWAD;
        emit BetaUpdated(_betaWAD);
        $.liquidationCoverageUtilizationWAD = _liquidationCoverageUtilizationWAD;
        emit LiquidationCoverageUtilizationUpdated(_liquidationCoverageUtilizationWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setLiquidityConfiguration(uint64 _minLiquidityWAD) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        // Validate the new liquidity configuration
        _validateLiquidityConfig(_minLiquidityWAD);
        _getRoycoDayAccountantStorage().minLiquidityWAD = _minLiquidityWAD;
        emit LiquidityUpdated(_minLiquidityWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setMaxYieldShares(uint64 _maxJTYieldShareWAD, uint64 _maxLTYieldShareWAD) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        // Validate the new yield share configuration: the maximum JT and LT yield shares must sum to at most 100% of senior appreciation
        _validateYieldShareConfig(_maxJTYieldShareWAD, _maxLTYieldShareWAD);
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        $.maxJTYieldShareWAD = _maxJTYieldShareWAD;
        $.maxLTYieldShareWAD = _maxLTYieldShareWAD;
        emit MaxYieldSharesUpdated(_maxJTYieldShareWAD, _maxLTYieldShareWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setFixedTermDuration(uint24 _fixedTermDurationSeconds) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        $.fixedTermDurationSeconds = _fixedTermDurationSeconds;
        // If the specified duration is 0, the market will permanently be in a perpetual state
        if (_fixedTermDurationSeconds == 0) {
            emit JuniorTrancheCoverageImpermanentLossReset($.lastJTCoverageImpermanentLoss);
            $.lastJTCoverageImpermanentLoss = ZERO_NAV_UNITS;
            $.lastMarketState = MarketState.PERPETUAL;
        }
        emit FixedTermDurationUpdated(_fixedTermDurationSeconds);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setSeniorTrancheDustTolerance(NAV_UNIT _stNAVDustTolerance) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        $.stNAVDustTolerance = _stNAVDustTolerance;
        // Update the cached effective NAV dust tolerance
        $.effectiveNAVDustTolerance = _stNAVDustTolerance + $.jtNAVDustTolerance;
        emit SeniorTrancheDustToleranceUpdated(_stNAVDustTolerance);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setJuniorTrancheDustTolerance(NAV_UNIT _jtNAVDustTolerance) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        $.jtNAVDustTolerance = _jtNAVDustTolerance;
        // Update the cached effective NAV dust tolerance
        $.effectiveNAVDustTolerance = $.stNAVDustTolerance + _jtNAVDustTolerance;
        emit JuniorTrancheDustToleranceUpdated(_jtNAVDustTolerance);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setLiquidityTrancheDustTolerance(NAV_UNIT _ltNAVDustTolerance) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        // The LT dust tolerance is independent of the effective NAV dust tolerance, which is bounded only by the ST and JT raw NAV dust tolerances
        _getRoycoDayAccountantStorage().ltNAVDustTolerance = _ltNAVDustTolerance;
        emit LiquidityTrancheDustToleranceUpdated(_ltNAVDustTolerance);
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Validates the coverage requirement parameters of the market
     * @param _minCoverageWAD The coverage ratio that the senior tranche is expected to be protected by, scaled to WAD precision
     * @param _betaWAD The JT's sensitivity to the same downside stress that affects ST, scaled to WAD precision
     * @param _liquidationCoverageUtilizationWAD The liquidation coverageUtilization threshold for this market, scaled to WAD precision
     */
    function _validateCoverageConfig(uint64 _minCoverageWAD, uint96 _betaWAD, uint256 _liquidationCoverageUtilizationWAD) internal pure {
        require(
            // Ensure that the coverage requirement is valid
            (_minCoverageWAD < WAD) && 
                // Ensure that beta is valid
                // NOTE: Beta cannot exceed 1 because the junior tranche should never be in a more loss-prone investment than the senior tranche
                (_betaWAD <= WAD) && 
                // Ensure that JT withdrawals are not permanently bricked
                (uint256(_minCoverageWAD).mulDiv(_betaWAD, WAD, Math.Rounding.Ceil) < WAD) && 
                // Ensure that the liquidation coverageUtilization threshold can only be breached once the NAVs have experienced losses
                (_liquidationCoverageUtilizationWAD > WAD),
            INVALID_COVERAGE_CONFIG()
        );
    }

    /**
     * @notice Validates the liquidity requirement parameters of the market
     * @param _minLiquidityWAD The percentage of the senior tranche NAV that must be in the liquidity tranche's market making inventory, scaled to WAD precision
     */
    function _validateLiquidityConfig(uint64 _minLiquidityWAD) internal pure {
        require(
            // Ensure that the liquidity requirement is valid
            (_minLiquidityWAD < WAD),
            INVALID_LIQUIDITY_CONFIG()
        );
    }

    /**
     * @notice Validates the yield share (premium) parameters of the market
     * @param _maxJTYieldShareWAD The maximum JT yield share (risk premium) as a percentage of senior appreciation, scaled to WAD precision
     * @param _maxLTYieldShareWAD The maximum LT yield share (liquidity premium) as a percentage of senior appreciation, scaled to WAD precision
     */
    function _validateYieldShareConfig(uint64 _maxJTYieldShareWAD, uint64 _maxLTYieldShareWAD) internal pure {
        // The combined maximum yield shares cannot exceed 100% of senior appreciation, so the risk and liquidity premiums always fit within the senior gain
        require((_maxJTYieldShareWAD + _maxLTYieldShareWAD) <= WAD, INVALID_MAX_YIELD_SHARE_CONFIG());
    }

    /**
     * @notice Initializes the YDM (Yield Distribution Model) if required for this market
     * @param _ydm The new YDM address to set
     * @param _ydmInitializationData The data used to initialize the new YDM for this market
     */
    function _initializeYDM(address _ydm, bytes calldata _ydmInitializationData) internal {
        // Ensure that the YDM is not null
        require(_ydm != address(0), NULL_ADDRESS());
        // Initialize the YDM if required
        if (_ydmInitializationData.length != 0) {
            (bool success, bytes memory data) = _ydm.call(_ydmInitializationData);
            require(success, FAILED_TO_INITIALIZE_YDM(data));
        }
    }

    // =============================
    // Accountant State Accessor Functions
    // =============================

    /// @inheritdoc IRoycoDayAccountant
    function getState() external view override(IRoycoDayAccountant) returns (RoycoDayAccountantState memory) {
        return _getRoycoDayAccountantStorage();
    }

    /**
     * @notice Returns a storage pointer to the RoycoDayAccountantState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the accountant's state
     */
    function _getRoycoDayAccountantStorage() internal pure returns (RoycoDayAccountantState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_DAY_ACCOUNTANT_STORAGE_SLOT
        }
    }
}
