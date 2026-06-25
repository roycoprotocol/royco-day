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
        NAV_UNIT _ltRawNAV // TODO: Incorporate
    )
        public
        override(IRoycoDayAccountant)
        onlyRoycoKernel
        returns (SyncedAccountingState memory state)
    {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Preview synchronization of the tranche NAVs and the JT coverage impermanent loss
        MarketState initialMarketState;
        bool riskPremiumPaid;
        NAV_UNIT jtCoverageImpermanentLossErased;
        (state, initialMarketState, riskPremiumPaid, jtCoverageImpermanentLossErased) =
            _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _ltRawNAV, _accrueJTYieldShare());

        // The JT risk premium was paid out of ST yield
        if (riskPremiumPaid) {
            // Reset the accumulator and update the last risk premium payment timestamp
            delete $.twJTYieldShareAccruedWAD;
            $.lastRiskPremiumPaymentTimestamp = uint32(block.timestamp);
        }

        // Checkpoint the resulting market state, mark-to-market NAVs, and the JT coverage impermanent loss
        $.lastMarketState = state.marketState;
        $.lastSTRawNAV = _stRawNAV;
        $.lastJTRawNAV = _jtRawNAV;
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
        NAV_UNIT _ltRawNAV // TODO: Incorporate
    )
        public
        view
        override(IRoycoDayAccountant)
        returns (SyncedAccountingState memory state)
    {
        (state,,,) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _ltRawNAV, _previewJTYieldShareAccrual());
    }

    /// @inheritdoc IRoycoDayAccountant
    function postOpSyncTrancheAccounting(
        Operation _op,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV, // TODO: Incorporate
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
        $.lastSTEffectiveNAV = stEffectiveNAV;
        $.lastJTEffectiveNAV = jtEffectiveNAV;

        // Marshal the post-sync state and return to the caller
        uint256 betaWAD = $.betaWAD;
        uint256 minCoverageWAD = $.minCoverageWAD;
        state = SyncedAccountingState({
            // The market state is guaranteed to be identical to the persisted
            marketState: $.lastMarketState,
            stRawNAV: _stRawNAV,
            jtRawNAV: _jtRawNAV,
            ltRawNAV: ZERO_NAV_UNITS, // TODO: Implement LT raw NAV
            stEffectiveNAV: stEffectiveNAV,
            jtEffectiveNAV: jtEffectiveNAV,
            jtCoverageImpermanentLoss: jtCoverageImpermanentLoss,
            // No protocol fees taken on deposit or withdrawal
            stProtocolFeeAccrued: ZERO_NAV_UNITS,
            jtProtocolFeeAccrued: ZERO_NAV_UNITS,
            ltProtocolFeeAccrued: ZERO_NAV_UNITS,
            coverageUtilizationWAD: UtilsLib.computeCoverageUtilization(_stRawNAV, _jtRawNAV, betaWAD, minCoverageWAD, jtEffectiveNAV),
            fixedTermEndTimestamp: $.fixedTermEndTimestamp,
            minCoverageWAD: minCoverageWAD,
            betaWAD: betaWAD,
            liquidationCoverageUtilizationWAD: $.liquidationCoverageUtilizationWAD
        });
    }

    /// @inheritdoc IRoycoDayAccountant
    function postOpSyncTrancheAccountingAndEnforceCoverage(
        Operation _op,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV // TODO: Incorporate
    )
        external
        override(IRoycoDayAccountant)
        returns (SyncedAccountingState memory state)
    {
        // Execute a post-op NAV synchronization
        // This is called during a ST Deposit or JT Withdrawal, so the self-liquidation bonus is not applicable
        state = postOpSyncTrancheAccounting(_op, _stRawNAV, _jtRawNAV, _ltRawNAV, ZERO_NAV_UNITS);
        // Enforce the market's coverage requirement
        require(_isDemandSatisfied(state.coverageUtilizationWAD), COVERAGE_REQUIREMENT_UNSATISFIED());
    }

    // =============================
    // Coverage and Liquidity Checking Functions
    // =============================

    /// @inheritdoc IRoycoDayAccountant
    function isCoverageRequirementSatisfied() public view override(IRoycoDayAccountant) returns (bool) {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // Compute the coverage utilization and return whether or the minimum coverage demand is satisfied based on persisted NAVs
        uint256 coverageUtilizationWAD = UtilsLib.computeCoverageUtilization($.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.minCoverageWAD, $.lastJTEffectiveNAV);
        return _isDemandSatisfied(coverageUtilizationWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function isLiquidityRequirementSatisfied() public view override(IRoycoDayAccountant) returns (bool) {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // Compute the liquidity utilization and return whether or the minimum liquidity demand is satisfied based on persisted NAVs
        uint256 liquidityUtilizationWAD = UtilsLib.computeLiquidityUtilization($.lastSTEffectiveNAV, $.minLiquidityWAD, $.lastLTRawNAV);
        return _isDemandSatisfied(liquidityUtilizationWAD);
    }

    /**
     * @inheritdoc IRoycoDayAccountant
     * @dev Coverage Invariant: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * β)) * MIN_COVERAGE
     * @dev Max assets depositable into ST, x: JT_EFFECTIVE_NAV = ((ST_RAW_NAV + x) + (JT_RAW_NAV * β)) * MIN_COVERAGE
     *      Isolate x: x = (JT_EFFECTIVE_NAV / MIN_COVERAGE) - (JT_RAW_NAV * β) - ST_RAW_NAV
     */
    function maxSTDepositGivenCoverage(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV
    )
        external
        view
        override(IRoycoDayAccountant)
        returns (NAV_UNIT maxSTDeposit)
    {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // Preview a NAV sync to get the market's current state
        (SyncedAccountingState memory state,,,) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _ltRawNAV, _previewJTYieldShareAccrual());
        // If there is no minimum coverage requirement, there is no ST capacity restriction
        if (state.minCoverageWAD == 0) return MAX_NAV_UNITS;
        // Solve for x, rounding in favor of senior protection
        // Compute the total covered assets by the junior tranche loss absorption buffer
        NAV_UNIT totalCoveredAssets = state.jtEffectiveNAV.mulDiv(WAD, state.minCoverageWAD, Math.Rounding.Floor);
        // Compute the assets required to cover current junior tranche exposure
        // Also account for JT's dust tolerance to preclude reverts due to rounding after ST deposit (if both are exposed to the same underlying rounding)
        NAV_UNIT jtCoverageRequired = _jtRawNAV.mulDiv(state.betaWAD, WAD, Math.Rounding.Ceil) + $.jtNAVDustTolerance;
        // Compute the amount of assets that can be deposited into senior while retaining full coverage
        // Also account for ST's dust tolerance to preclude reverts due to rounding after ST deposit
        maxSTDeposit = totalCoveredAssets.saturatingSub(jtCoverageRequired).saturatingSub(_stRawNAV).saturatingSub($.stNAVDustTolerance);
    }

    /**
     * @inheritdoc IRoycoDayAccountant
     * @dev Coverage Invariant: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * β)) * MIN_COVERAGE
     * @dev When assets are claimed from the JT, they are always liquidated in the same proportion as the tranche's total claims on the ST and JT assets
     * @dev Let S be the JT's total claims on ST assets and J be the JT's total claims on JT assets, in NAV Units. The total claims on the ST and JT assets are S + J NAV Units
     * @dev Let K_S be S / (S + J) and K_J be J / (S + J)
     * @dev Therefore, if a total NAV of y is claimed from the JT, K_S * y will be claimed from the ST_RAW_NAV and K_J * y will be claimed from the JT_RAW_NAV
     * @dev Max assets withdrawable from JT, y: (JT_EFFECTIVE_NAV - y) = ((ST_RAW_NAV - K_S * y) + ((JT_RAW_NAV - K_J * y) * β)) * COV
     *      Isolate y: y = (JT_EFFECTIVE_NAV - (MIN_COVERAGE * (ST_RAW_NAV + (JT_RAW_NAV * β)))) / (1 - (MIN_COVERAGE * (K_S + β * K_J)))
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
        override(IRoycoDayAccountant)
        returns (NAV_UNIT totalNAVClaimable, NAV_UNIT stClaimable, NAV_UNIT jtClaimable)
    {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Get the surplus JT assets in NAV units
        // Preview a NAV sync to get the market's current state
        (SyncedAccountingState memory state,,,) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _ltRawNAV, _previewJTYieldShareAccrual());
        uint256 betaWAD = $.betaWAD;
        // Compute the total covered exposure of the underlying investment, rounding in favor of senior protection
        NAV_UNIT totalCoveredExposure = _stRawNAV + _jtRawNAV.mulDiv(betaWAD, WAD, Math.Rounding.Ceil);
        // Compute the minimum junior tranche assets required to cover the exposure as per the market's coverage requirement
        NAV_UNIT requiredJTAssets = totalCoveredExposure.mulDiv($.minCoverageWAD, WAD, Math.Rounding.Ceil);
        // Compute the surplus coverage currently provided by the junior tranche based on its currently remaining loss-absorption buffer
        // Also account for the effective dust tolerance required to preclude reverts due to rounding after JT redemptions
        NAV_UNIT surplusJTAssets = state.jtEffectiveNAV.saturatingSub(requiredJTAssets)
            .saturatingSub($.stNAVDustTolerance + $.jtNAVDustTolerance.mulDiv(betaWAD, WAD, Math.Rounding.Ceil)).
            // Additionally absorb the worst case inner-ceil rounding in the coverageUtilization computation
            saturatingSub(toNAVUnits(uint256(2)));
        if (surplusJTAssets == ZERO_NAV_UNITS) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS);

        // Compute the total JT claim on NAV and preemptively return if zero
        NAV_UNIT totalJTClaims = _jtClaimOnStUnits + _jtClaimOnJtUnits;
        if (totalJTClaims == ZERO_NAV_UNITS) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        // Calculate K_S
        uint256 kS_WAD = _jtClaimOnStUnits.mulDiv(WAD, totalJTClaims, Math.Rounding.Floor);
        // Calculate K_J
        uint256 kJ_WAD = _jtClaimOnJtUnits.mulDiv(WAD, totalJTClaims, Math.Rounding.Floor);
        // Compute how much coverage the system retains per 1 nav unit of JT assets withdrawn scaled to WAD precision
        uint256 coverageRetentionWAD =
            (WAD - uint256($.minCoverageWAD).mulDiv(kS_WAD + uint256(betaWAD).mulDiv(kJ_WAD, WAD, Math.Rounding.Floor), WAD, Math.Rounding.Floor));
        // Calculate how much of the surplus can be withdrawn while satisfying the coverage requirement
        totalNAVClaimable = surplusJTAssets.mulDiv(WAD, coverageRetentionWAD, Math.Rounding.Floor);
        if (totalNAVClaimable == ZERO_NAV_UNITS) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS);

        // Split it into individual tranche's claims
        stClaimable = totalNAVClaimable.mulDiv(kS_WAD, WAD, Math.Rounding.Floor);
        jtClaimable = totalNAVClaimable.mulDiv(kJ_WAD, WAD, Math.Rounding.Floor);
    }

    /**
     * @notice Returns whether the demand placed on a capital pool's service is satisfied given the service's utilization
     * @dev Utilization is the ratio of demand for the service to the pool's capacity to supply it, scaled to WAD precision
     * @dev Demand is satisfied when utilization does not exceed 100% (the pool's capacity meets or exceeds the minimum supply demanded from it)
     * @param _utilizationWAD The utilization of the service, scaled to WAD precision
     * @return satisfied A boolean indicating whether the demand placed on the service is satisfied
     */
    function _isDemandSatisfied(uint256 _utilizationWAD) internal pure returns (bool) {
        return (_utilizationWAD <= WAD);
    }

    // =============================
    // Internal NAV Synchronization and Yield Share Accrual Functions
    // =============================

    /**
     * @notice Synchronizes all tranche NAVs and the JT coverage impermanent loss based on unrealized PNLs of the underlying investment(s)
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _ltRawNAV The liquidity tranche's current raw NAV: the pure value of its invested assets
     * @param _twJTYieldShareAccruedWAD The currently accrued time-weighted JT yield share (JT YDM output) since the last distribution, scaled to WAD precision
     * @return state A struct containing all mark-to-market NAV, JT coverage impermanent loss, and fee data after executing the sync
     * @return initialMarketState The initial state the market was in before the synchronization
     * @return riskPremiumPaid A boolean indicating whether the JT risk premium was paid out of ST yield
     * @return jtCoverageImpermanentLossErased The amount of JT coverage loss erased (reset to 0)
     */
    function _previewSyncTrancheAccounting(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV, // TODO: Incorporate
        uint192 _twJTYieldShareAccruedWAD
    )
        internal
        view
        returns (SyncedAccountingState memory state, MarketState initialMarketState, bool riskPremiumPaid, NAV_UNIT jtCoverageImpermanentLossErased)
    {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // The market state that this sync transitions from
        initialMarketState = $.lastMarketState;

        // Build the last committed checkpoint from persisted state for the waterfall to settle against
        AccountingCheckpoint memory checkpoint = AccountingCheckpoint({
            stRawNAV: $.lastSTRawNAV,
            jtRawNAV: $.lastJTRawNAV,
            stEffectiveNAV: $.lastSTEffectiveNAV,
            jtEffectiveNAV: $.lastJTEffectiveNAV,
            jtCoverageImpermanentLoss: $.lastJTCoverageImpermanentLoss
        });

        // Resolve the JT YDM inputs consumed by the waterfall's yield split once per sync
        uint256 elapsedSinceLastRiskPremiumPayment = block.timestamp - $.lastRiskPremiumPaymentTimestamp;
        // The instantaneous share is only consumed when the last distribution happened in the same block, so it is fetched lazily
        // The JT YDM is driven by the market's coverage utilization: the JT risk premium scales with how utilized the JT coverage buffer is
        uint256 instantaneousJTYieldShareWAD = elapsedSinceLastRiskPremiumPayment == 0
            ? IYDM($.jtYDM)
                .previewYieldShare(
                    initialMarketState, UtilsLib.computeCoverageUtilization($.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.minCoverageWAD, $.lastJTEffectiveNAV)
                )
            : 0;
        // The JT yield share can never exceed 100% of senior appreciation: a larger share means the JT YDM is faulty
        require(instantaneousJTYieldShareWAD <= WAD, INVALID_YDM_OUTPUT());

        // Cache the effective NAV dust tolerance: the worst-case dust is bounded by the sum of the raw NAV dust tolerances
        NAV_UNIT effectiveNAVDustTolerance = $.effectiveNAVDustTolerance;

        // Execute the PnL attribution and settlement waterfall
        NAV_UNIT stProtocolFeeAccrued;
        NAV_UNIT jtProtocolFeeAccrued;
        (checkpoint, stProtocolFeeAccrued, jtProtocolFeeAccrued, riskPremiumPaid) = AccountingLib.applyProfitAndLossWaterfall(
            _stRawNAV,
            _jtRawNAV,
            PnLWaterfallParams({
                checkpoint: checkpoint,
                twJTYieldShareAccruedWAD: _twJTYieldShareAccruedWAD,
                instantaneousJTYieldShareWAD: instantaneousJTYieldShareWAD,
                elapsedSinceLastRiskPremiumPayment: elapsedSinceLastRiskPremiumPayment,
                stProtocolFeeWAD: $.stProtocolFeeWAD,
                jtProtocolFeeWAD: $.jtProtocolFeeWAD,
                jtYieldShareProtocolFeeWAD: $.jtYieldShareProtocolFeeWAD,
                effectiveNAVDustTolerance: effectiveNAVDustTolerance
            })
        );

        // Apply the market state transition resulting from this sync and marshal the post-sync state
        (state, jtCoverageImpermanentLossErased) = AccountingLib.applyStateTransition(
            initialMarketState,
            MarketStateTransitionParams({
                postPnLWaterfallCheckpoint: checkpoint,
                stProtocolFeeAccrued: stProtocolFeeAccrued,
                jtProtocolFeeAccrued: jtProtocolFeeAccrued,
                betaWAD: $.betaWAD,
                minCoverageWAD: $.minCoverageWAD,
                effectiveNAVDustTolerance: effectiveNAVDustTolerance,
                fixedTermDurationSeconds: $.fixedTermDurationSeconds,
                fixedTermEndTimestamp: $.fixedTermEndTimestamp,
                liquidationCoverageUtilizationWAD: $.liquidationCoverageUtilizationWAD,
                currentTimestamp: block.timestamp
            })
        );
    }

    /**
     * @notice Accrues the JT yield share since the last yield distribution
     * @dev Gets the instantaneous JT yield share and weights it by the time elapsed since the last accrual
     * @return twJTYieldShareAccruedWAD The updated time-weighted JT yield share since the last yield distribution
     */
    function _accrueJTYieldShare() internal returns (uint192 twJTYieldShareAccruedWAD) {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $.lastJTYieldShareAccrualTimestamp;
        if (lastUpdate == 0) {
            // Initialize the checkpoint timestamps if this is the first accrual
            $.lastJTYieldShareAccrualTimestamp = uint32(block.timestamp);
            $.lastRiskPremiumPaymentTimestamp = uint32(block.timestamp);
            return 0;
        }

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return $.twJTYieldShareAccruedWAD;

        // Get the instantaneous JT yield share, scaled to WAD precision, driven by the market's coverage utilization
        uint256 jtYieldShareWAD = IYDM($.jtYDM)
            .yieldShare(
                $.lastMarketState, UtilsLib.computeCoverageUtilization($.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.minCoverageWAD, $.lastJTEffectiveNAV)
            );
        // The JT yield share can never exceed 100% of senior appreciation: a larger share means the JT YDM is faulty
        require(jtYieldShareWAD <= WAD, INVALID_YDM_OUTPUT());

        // Accrue the time-weighted yield share accrued to JT since the last tranche interaction
        twJTYieldShareAccruedWAD = ($.twJTYieldShareAccruedWAD += uint192(jtYieldShareWAD * elapsed));
        $.lastJTYieldShareAccrualTimestamp = uint32(block.timestamp);

        emit JuniorTrancheYieldShareAccrued(jtYieldShareWAD, twJTYieldShareAccruedWAD);
    }

    /**
     * @notice Computes and returns the currently accrued JT yield share since the last yield distribution
     * @dev Gets the instantaneous JT yield share and weights it by the time elapsed since the last accrual
     * @return The updated time-weighted JT yield share since the last yield distribution
     */
    function _previewJTYieldShareAccrual() internal view returns (uint192) {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $.lastJTYieldShareAccrualTimestamp;
        if (lastUpdate == 0) return 0;

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return $.twJTYieldShareAccruedWAD;

        // Get the instantaneous JT yield share, scaled to WAD precision, driven by the market's coverage utilization
        uint256 jtYieldShareWAD = IYDM($.jtYDM)
            .previewYieldShare(
                $.lastMarketState, UtilsLib.computeCoverageUtilization($.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.minCoverageWAD, $.lastJTEffectiveNAV)
            );
        // The JT yield share can never exceed 100% of senior appreciation: a larger share means the JT YDM is faulty
        require(jtYieldShareWAD <= WAD, INVALID_YDM_OUTPUT());

        // Apply the accrual of JT yield share to the accumulator, weighted by the time elapsed
        return ($.twJTYieldShareAccruedWAD + uint192(jtYieldShareWAD * elapsed));
    }

    // =============================
    // Administrative Functions
    // =============================

    /// @inheritdoc IRoycoDayAccountant
    function setJuniorTrancheYDM(address _jtYDM, bytes calldata _jtYDMInitializationData) external override(IRoycoDayAccountant) restricted {
        // Best-effort sync to settle unrealized PNL under the outgoing JT YDM
        // NOTE: A reverting sync is tolerated since this setter is the only recovery path from a sync-bricking JT YDM
        KERNEL.call(abi.encodeCall(IRoycoDayKernel.syncTrancheAccounting, ()));
        // Initialize and set the new JT YDM for this market
        _initializeYDM(_jtYDM, _jtYDMInitializationData);
        _getRoycoDayAccountantStorage().jtYDM = _jtYDM;
        emit JuniorTrancheYDMUpdated(_jtYDM);
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
    function setJTYieldShareProtocolFee(uint64 _jtYieldShareProtocolFeeWAD) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        // Ensure that the protocol fee percentage is valid
        require(_jtYieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        _getRoycoDayAccountantStorage().jtYieldShareProtocolFeeWAD = _jtYieldShareProtocolFeeWAD;
        emit JuniorTrancheYieldShareProtocolFeeUpdated(_jtYieldShareProtocolFeeWAD);
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
     * @param _minLiquidityWAD The liquidity ratio that the senior tranche is expected to be provided liquidity by, scaled to WAD precision
     */
    function _validateLiquidityConfig(uint64 _minLiquidityWAD) internal pure {
        require(
            // Ensure that the liquidity requirement is valid
            (_minLiquidityWAD < WAD),
            INVALID_LIQUIDITY_CONFIG()
        );
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
    function getState() external pure override(IRoycoDayAccountant) returns (RoycoDayAccountantState memory) {
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
