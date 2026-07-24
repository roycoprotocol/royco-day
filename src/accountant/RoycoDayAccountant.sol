// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoDayAccountant } from "../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { IYDM } from "../interfaces/IYDM.sol";
import { MAX_NAV_UNITS, MAX_PROTOCOL_FEE_WAD, WAD, ZERO_NAV_UNITS } from "../libraries/Constants.sol";
import { MarketState, NAV_UNIT, Operation, SyncedAccountingState } from "../libraries/Types.sol";
import { Math, RoycoUnitsMath, toNAVUnits } from "../libraries/Units.sol";
import { UtilizationLogic } from "../libraries/logic/UtilizationLogic.sol";

/**
 * @title RoycoDayAccountant
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Performs and tracks the accounting, coverage, and liquidity operations and requirements for a Royco market
 * @notice Responsible for marking tranche NAVs to market, tracking the JT impermanent loss, distributing yield via the JT and LPT YDM, and computing protocol fees
 */
contract RoycoDayAccountant is IRoycoDayAccountant, RoycoBase {
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for uint256;

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
    /// @param _kernel The kernel that this accountant maintains mark-to-market NAV, JT impermanent loss, and fee accounting for
    constructor(address _kernel) {
        // Ensure the specified kernel is not null and immutably set it
        require((KERNEL = _kernel) != address(0), NULL_ADDRESS());
    }

    /**
     * @notice Initializes the Royco accountant state
     * @param _params The initialization parameters for the Royco accountant
     * @param _initialAuthority The initial authority for the Royco accountant
     */
    function initialize(RoycoDayAccountantInitParams calldata _params, address _initialAuthority) external initializer {
        // Initialize the base state of the accountant
        __RoycoBase_init(_initialAuthority);

        // Validate the accountant initialization parameters
        // Ensure that the protocol fee percentages are valid
        require(
            _params.stProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD && _params.jtProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD
                && _params.jtYieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD && _params.lptYieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD,
            MAX_PROTOCOL_FEE_EXCEEDED()
        );
        // Ensure that the YDMs are not identical: each tranche requires its own YDM instance: the YDMs are initialized per market and the adaptive models keep per-market curve state, so sharing one instance would corrupt both premiums by interleaving coverage and liquidity driven updates
        require(_params.jtYDM != _params.lptYDM, YDMS_CANNOT_BE_IDENTICAL());
        // Ensure that the coverage requirement must require less coverage than the entire senior exposure and the liquidation coverage utilization threshold can only be breached once the NAVs have experienced losses
        require(_params.minCoverageWAD < WAD && _params.coverageLiquidationUtilizationWAD > WAD, INVALID_COVERAGE_CONFIG());
        // Ensure that the liquidity requirement must require less market-making depth than the entire senior tranche claims
        require(_params.minLiquidityWAD < WAD, INVALID_LIQUIDITY_CONFIG());
        // Ensure that the max JT and LPT yield shares do not sum to greater than 100% of senior appreciation
        _validateYieldShareConfig(_params.maxJTYieldShareWAD, _params.maxLPTYieldShareWAD);

        // Initialize the accountant and YDM state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Set the fields in slot 0 of storage
        $.stProtocolFeeWAD = _params.stProtocolFeeWAD;
        $.jtProtocolFeeWAD = _params.jtProtocolFeeWAD;
        $.jtYieldShareProtocolFeeWAD = _params.jtYieldShareProtocolFeeWAD;
        $.lptYieldShareProtocolFeeWAD = _params.lptYieldShareProtocolFeeWAD;
        emit SeniorTrancheProtocolFeeUpdated(_params.stProtocolFeeWAD);
        emit JuniorTrancheProtocolFeeUpdated(_params.jtProtocolFeeWAD);
        emit JuniorTrancheYieldShareProtocolFeeUpdated(_params.jtYieldShareProtocolFeeWAD);
        emit LiquidityProviderTrancheYieldShareProtocolFeeUpdated(_params.lptYieldShareProtocolFeeWAD);

        // Set the fields in slot 1 of storage
        $.minCoverageWAD = _params.minCoverageWAD;
        $.fixedTermDurationSeconds = _params.fixedTermDurationSeconds;
        emit CoverageUpdated(_params.minCoverageWAD);
        emit FixedTermDurationUpdated(_params.fixedTermDurationSeconds);

        // Set the fields in slot 2 of storage
        $.jtYDM = _params.jtYDM;
        emit JuniorTrancheYDMUpdated(_params.jtYDM);

        // Set the fields in slot 3 of storage
        $.lptYDM = _params.lptYDM;
        $.minLiquidityWAD = _params.minLiquidityWAD;
        emit LiquidityProviderTrancheYDMUpdated(_params.lptYDM);
        emit LiquidityUpdated(_params.minLiquidityWAD);

        // Set the maximum yield shares in slot 4 and slot 5 of storage (their time-weighted accumulators are zero-initialized)
        $.maxJTYieldShareWAD = _params.maxJTYieldShareWAD;
        $.maxLPTYieldShareWAD = _params.maxLPTYieldShareWAD;
        emit MaxYieldSharesUpdated(_params.maxJTYieldShareWAD, _params.maxLPTYieldShareWAD);

        // Set the rest of the fields
        $.coverageLiquidationUtilizationWAD = _params.coverageLiquidationUtilizationWAD;
        $.dustTolerance = _params.dustTolerance;
        emit LiquidationCoverageUtilizationUpdated(_params.coverageLiquidationUtilizationWAD);
        emit DustToleranceUpdated(_params.dustTolerance);

        // Initialize the JT and LPT YDMs for this market
        _initializeYDM(_params.jtYDM, _params.jtYDMInitializationData);
        _initializeYDM(_params.lptYDM, _params.lptYDMInitializationData);
    }

    // =============================
    // NAV Synchronization Functions
    // =============================

    /// @inheritdoc IRoycoDayAccountant
    function preOpSyncTrancheAccounting(NAV_UNIT _collateralNAV)
        public
        override(IRoycoDayAccountant)
        onlyRoycoKernel
        returns (SyncedAccountingState memory state)
    {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Accrue the JT and LPT yield shares, then preview the synchronization of the tranche NAVs and the JT impermanent loss
        MarketState initialMarketState;
        bool premiumsPaid;
        NAV_UNIT jtImpermanentLossErased;
        (uint128 twJTYieldShareAccruedWAD, uint128 twLPTYieldShareAccruedWAD) = _accruePremiumYieldShares();
        (state, initialMarketState, premiumsPaid, jtImpermanentLossErased) =
            _previewSyncTrancheAccounting(_collateralNAV, twJTYieldShareAccruedWAD, twLPTYieldShareAccruedWAD);

        // The JT risk and LPT liquidity premiums were paid out of ST yield
        if (premiumsPaid) {
            // Reset the accumulators and update the last premium payment timestamp
            delete $.twJTYieldShareAccruedWAD;
            delete $.twLPTYieldShareAccruedWAD;
            $.lastPremiumPaymentTimestamp = uint32(block.timestamp);
        }

        // Checkpoint the resulting market state, mark-to-market senior/junior NAVs, and the JT impermanent loss
        // The liquidity provider tranche raw NAV is committed subsequently since it is composed of ST shares, which are dependenent on the final ST effective NAV and total share supply
        $.lastMarketState = state.marketState;
        $.lastCollateralNAV = _collateralNAV;
        $.lastSTEffectiveNAV = state.stEffectiveNAV;
        $.lastJTEffectiveNAV = state.jtEffectiveNAV;
        $.lastJTImpermanentLoss = state.jtImpermanentLoss;

        // If the market transitioned from a perpetual to a fixed-term state, set the end timestamp of the fixed-term
        if (initialMarketState == MarketState.PERPETUAL && state.marketState == MarketState.FIXED_TERM) {
            emit FixedTermCommenced(($.fixedTermEndTimestamp = state.fixedTermEndTimestamp));
        } else if (initialMarketState == MarketState.FIXED_TERM && state.marketState == MarketState.PERPETUAL) {
            // Reset the fixed-term end timestamp
            delete $.fixedTermEndTimestamp;
            emit FixedTermEnded();
        }

        // If the JT IL was erased, signal the resetting
        if (jtImpermanentLossErased != ZERO_NAV_UNITS) emit JuniorTrancheImpermanentLossReset(jtImpermanentLossErased);

        emit TrancheAccountingSynced(state);
    }

    /// @inheritdoc IRoycoDayAccountant
    function commitLiquidityProviderTrancheRawNAV(NAV_UNIT _freshLPTRawNAV) external override(IRoycoDayAccountant) onlyRoycoKernel {
        // Commit the freshly marked liquidity provider tranche raw NAV: the kernel marks it after the sync commits the senior/junior NAVs and mints any fee shares
        // The LPT raw NAV is dependent on the fresh ST share price which is resolved on the preceding pre-op synchronization
        _getRoycoDayAccountantStorage().lastLPTRawNAV = _freshLPTRawNAV;
        emit LiquidityProviderTrancheRawNAVCommitted(_freshLPTRawNAV);
    }

    /// @inheritdoc IRoycoDayAccountant
    function previewSyncTrancheAccounting(NAV_UNIT _collateralNAV) public view override(IRoycoDayAccountant) returns (SyncedAccountingState memory state) {
        (uint128 twJTYieldShareAccruedWAD, uint128 twLPTYieldShareAccruedWAD) = _previewPremiumYieldShareAccrual();
        (state,,,) = _previewSyncTrancheAccounting(_collateralNAV, twJTYieldShareAccruedWAD, twLPTYieldShareAccruedWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function postOpSyncTrancheAccounting(
        Operation _op,
        NAV_UNIT _collateralNAV,
        NAV_UNIT _lptRawNAV,
        NAV_UNIT _stSelfLiquidationBonusNAV,
        bool _enforceCoverageAndLiquidityRequirements
    )
        public
        override(IRoycoDayAccountant)
        onlyRoycoKernel
        returns (SyncedAccountingState memory state)
    {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Cache the last checkpointed tranche NAVs
        NAV_UNIT stEffectiveNAV = $.lastSTEffectiveNAV;
        NAV_UNIT jtEffectiveNAV = $.lastJTEffectiveNAV;

        // Compute the deltas in the collateral and liquidity provider tranche raw NAVs
        int256 deltaCollateralNAV = RoycoUnitsMath.computeNAVDelta(_collateralNAV, $.lastCollateralNAV);
        int256 deltaLPTRawNAV = RoycoUnitsMath.computeNAVDelta(_lptRawNAV, $.lastLPTRawNAV);

        // Apply the effects of the operation that was executed
        if (_op == Operation.ST_DEPOSIT) {
            require(deltaCollateralNAV > 0 && deltaLPTRawNAV == 0 && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
            // New ST deposits are treated as an addition to the future ST exposure
            stEffectiveNAV = (stEffectiveNAV + toNAVUnits(deltaCollateralNAV));
        } else if (_op == Operation.JT_DEPOSIT) {
            require(deltaCollateralNAV > 0 && deltaLPTRawNAV == 0 && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
            // New JT deposits are treated as an addition to the future loss-absorption buffer
            jtEffectiveNAV = (jtEffectiveNAV + toNAVUnits(deltaCollateralNAV));
        } else if (_op == Operation.LPT_DEPOSIT) {
            // An in-kind LPT deposit only adds market-making inventory, the collateral cannot move
            require(deltaLPTRawNAV > 0 && deltaCollateralNAV == 0 && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
        } else if (_op == Operation.LPT_MULTI_ASSET_DEPOSIT) {
            // A multi-asset LPT deposit adds market-making inventory and can mint and deploy new ST shares for its senior leg
            require(deltaLPTRawNAV > 0 && deltaCollateralNAV >= 0 && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
            stEffectiveNAV = (stEffectiveNAV + toNAVUnits(deltaCollateralNAV));
        } else if (_op == Operation.LPT_REDEEM) {
            // An in-kind LPT redemption only transfers out market-making inventory and idle premium shares, the collateral cannot move and no bonus is paid
            require(deltaLPTRawNAV <= 0 && deltaCollateralNAV == 0 && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
        } else {
            // Compute the total value redeemed from the collateral
            NAV_UNIT collateralRedemptionNAV = toNAVUnits(-deltaCollateralNAV);
            if (_op == Operation.ST_REDEEM || _op == Operation.LPT_MULTI_ASSET_REDEEM) {
                if (_op == Operation.ST_REDEEM) require(deltaLPTRawNAV == 0 && collateralRedemptionNAV > ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
                else require(deltaLPTRawNAV <= 0, INVALID_POST_OP_STATE(_op));
                // Reduce JT effective NAV by the bonus provided from its assets
                jtEffectiveNAV = (jtEffectiveNAV - _stSelfLiquidationBonusNAV);
                // Reduce ST effective NAV by the total redemptions without the bonus provided from JT effective NAV
                stEffectiveNAV = (stEffectiveNAV - (collateralRedemptionNAV - _stSelfLiquidationBonusNAV));
            } else if (_op == Operation.JT_REDEEM) {
                // JT cannot get a bonus from its own NAV, and a junior redemption leaves the senior exposure and supply untouched so it cannot move the liquidity provider tranche mark
                require(
                    deltaLPTRawNAV == 0 && collateralRedemptionNAV > ZERO_NAV_UNITS && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op)
                );
                // The actual amount withdrawn from JT effective NAV could be from both tranches (its own share of its NAV, ST yield share, IL repayments, etc.)
                jtEffectiveNAV = (jtEffectiveNAV - collateralRedemptionNAV);
            }
        }

        // Enforce the NAV conservation invariant
        require((_collateralNAV == (stEffectiveNAV + jtEffectiveNAV)), NAV_CONSERVATION_VIOLATION());

        // Checkpoint the mark-to-market tranche NAVs
        $.lastCollateralNAV = _collateralNAV;
        $.lastLPTRawNAV = _lptRawNAV;
        $.lastSTEffectiveNAV = stEffectiveNAV;
        $.lastJTEffectiveNAV = jtEffectiveNAV;

        // Marshal the post-sync state and return to the caller
        uint256 minCoverageWAD = $.minCoverageWAD;
        uint256 minLiquidityWAD = $.minLiquidityWAD;
        state = SyncedAccountingState({
            // The market state is guaranteed to be identical to the persisted
            marketState: $.lastMarketState,
            collateralNAV: _collateralNAV,
            lptRawNAV: _lptRawNAV,
            stEffectiveNAV: stEffectiveNAV,
            jtEffectiveNAV: jtEffectiveNAV,
            jtImpermanentLoss: $.lastJTImpermanentLoss,
            // No liquidity premium accrued on deposit or withdrawal: the premium is only paid on senior appreciation
            lptLiquidityPremium: ZERO_NAV_UNITS,
            // No protocol fees taken on deposit or withdrawal
            stProtocolFee: ZERO_NAV_UNITS,
            jtProtocolFee: ZERO_NAV_UNITS,
            lptProtocolFee: ZERO_NAV_UNITS,
            coverageUtilizationWAD: UtilizationLogic._computeCoverageUtilization(_collateralNAV, minCoverageWAD, jtEffectiveNAV),
            liquidityUtilizationWAD: UtilizationLogic._computeLiquidityUtilization(stEffectiveNAV, minLiquidityWAD, _lptRawNAV),
            fixedTermEndTimestamp: $.fixedTermEndTimestamp,
            minCoverageWAD: minCoverageWAD,
            coverageLiquidationUtilizationWAD: $.coverageLiquidationUtilizationWAD,
            minLiquidityWAD: minLiquidityWAD
        });

        // Preemptively return if the kernel specified that the market's requirements don't need to be enforced
        if (!_enforceCoverageAndLiquidityRequirements) return state;

        // Enforce the coverage requirement for operations that can violate it (add senior exposure or remove the junior loss-absorption buffer)
        // An in-kind LPT deposit cannot add senior exposure, only the multi-asset variant mints a senior leg
        if (_op == Operation.ST_DEPOSIT || _op == Operation.LPT_MULTI_ASSET_DEPOSIT || _op == Operation.JT_REDEEM) {
            require(state.coverageUtilizationWAD <= WAD, COVERAGE_REQUIREMENT_VIOLATED());
        }

        // Enforce the liquidity requirement for operations that can violate it (raise the senior exposure or reduce the depth of the liquidity provider tranche)
        // An in-kind LPT deposit only deepens liquidity so it is exempt, both LPT redemption variants remove depth
        if (_op == Operation.ST_DEPOSIT || _op == Operation.LPT_MULTI_ASSET_DEPOSIT || _op == Operation.LPT_REDEEM || _op == Operation.LPT_MULTI_ASSET_REDEEM) {
            require(state.liquidityUtilizationWAD <= WAD, LIQUIDITY_REQUIREMENT_VIOLATED());
        }
    }

    // =============================
    // Coverage and Liquidity Checking Functions
    // =============================

    /**
     * @inheritdoc IRoycoDayAccountant
     * @dev ST deposits are bounded by the coverage and liquidity requirements of the market
     *
     * @dev Coverage Requirement: JT_EFFECTIVE_NAV >= COLLATERAL_NAV * MIN_COVERAGE
     * @dev Max assets depositable into ST, x: JT_EFFECTIVE_NAV = (COLLATERAL_NAV + x) * MIN_COVERAGE
     *      Isolate x: x = (JT_EFFECTIVE_NAV / MIN_COVERAGE) - COLLATERAL_NAV
     *
     * @dev Liquidity Requirement: LPT_RAW_NAV >= (ST_EFFECTIVE_NAV * MIN_LIQUIDITY)
     * @dev Max assets depositable into ST, x': LPT_RAW_NAV = ((ST_EFFECTIVE_NAV + x') * MIN_LIQUIDITY)
     *      Isolate x': x' = (LPT_RAW_NAV / MIN_LIQUIDITY) - ST_EFFECTIVE_NAV
     *
     * @dev The maximum ST deposit NAV is the minimum of x and x'
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
            NAV_UNIT totalCoveredValue = state.jtEffectiveNAV.mulDiv(WAD, state.minCoverageWAD, Math.Rounding.Floor);
            // Compute the value of assets that can be deposited into senior while retaining minimum coverage
            // Also account for the dust tolerance to preclude reverts due to rounding after ST deposit
            maxSTDepositGivenCoverage = totalCoveredValue.saturatingSub((state.collateralNAV + $.dustTolerance));
        }

        //  Compute the max ST deposit given the liquidity requirement
        // If there is no minimum liquidity requirement, there is no ST capacity restriction
        NAV_UNIT maxSTDepositGivenLiquidity = MAX_NAV_UNITS;
        if (state.minLiquidityWAD != 0) {
            // Solve for x', rounding in favor of senior protection
            // Compute the maximum value ownable by the senior tranche given the current value of the market making inventory
            NAV_UNIT maxSTEffectiveNAV = state.lptRawNAV.mulDiv(WAD, state.minLiquidityWAD, Math.Rounding.Floor);
            // Compute the value of assets that can be deposited into senior while retaining minimum liquidity
            // Also account for the dust tolerance to preclude reverts due to rounding after ST deposit
            maxSTDepositGivenLiquidity = maxSTEffectiveNAV.saturatingSub(state.stEffectiveNAV + $.dustTolerance);
        }

        // The maximum deposit is the minimum of x and x'
        return RoycoUnitsMath.min(maxSTDepositGivenCoverage, maxSTDepositGivenLiquidity);
    }

    /**
     * @inheritdoc IRoycoDayAccountant
     * @dev JT withdrawals are bounded by the coverage requirement of the market
     *
     * @dev Coverage Requirement: JT_EFFECTIVE_NAV >= COLLATERAL_NAV * MIN_COVERAGE
     * @dev Max assets withdrawable from JT, y: JT_EFFECTIVE_NAV - y = (COLLATERAL_NAV - y) * MIN_COVERAGE
     * @dev Isolate y: y = (JT_EFFECTIVE_NAV - (COLLATERAL_NAV * MIN_COVERAGE)) / (1 - MIN_COVERAGE)
     */
    function maxJTWithdrawal(SyncedAccountingState memory state) external view override(IRoycoDayAccountant) returns (NAV_UNIT) {
        // Compute the minimum junior tranche assets required to cover the collateral as per the market's coverage requirement, rounding in favor of senior protection
        // Also account for the dust tolerance required to preclude reverts due to rounding after JT redemptions
        NAV_UNIT requiredJTValue = (state.collateralNAV + _getRoycoDayAccountantStorage().dustTolerance).mulDiv(state.minCoverageWAD, WAD, Math.Rounding.Ceil);
        // Compute the surplus coverage currently provided by the junior tranche based on its currently remaining loss-absorption buffer
        NAV_UNIT surplusJTValue = state.jtEffectiveNAV.saturatingSub(requiredJTValue);

        // Solve for y, rounding in favor of senior protection
        return surplusJTValue.mulDiv(WAD, (WAD - state.minCoverageWAD), Math.Rounding.Floor);
    }

    /**
     * @inheritdoc IRoycoDayAccountant
     * @dev LPT withdrawals are bounded by the liquidity requirement of the market
     *
     * @dev Liquidity Requirement: LPT_RAW_NAV >= (ST_EFFECTIVE_NAV * MIN_LIQUIDITY)
     * @dev Max assets withdrawable from LPT, z: (LPT_RAW_NAV - z) = (ST_EFFECTIVE_NAV * MIN_LIQUIDITY)
     *      Isolate z: z = LPT_RAW_NAV - (ST_EFFECTIVE_NAV * MIN_LIQUIDITY)
     */
    function maxLPTWithdrawal(SyncedAccountingState memory state) external view override(IRoycoDayAccountant) returns (NAV_UNIT) {
        // If there is no minimum liquidity requirement, there is no LPT withdrawal restriction
        if (state.minLiquidityWAD == 0) return state.lptRawNAV;
        // Compute the minimum market-making depth required to satisfy the market's liquidity requirement, rounding in favor of senior protection
        // Also account for the dust tolerance to preclude reverts due to rounding after LPT redemptions
        NAV_UNIT requiredLPTValue =
            (state.stEffectiveNAV + _getRoycoDayAccountantStorage().dustTolerance).mulDiv(state.minLiquidityWAD, WAD, Math.Rounding.Ceil);
        // Compute the surplus depth that can be withdrawn while retaining minimum liquidity
        return state.lptRawNAV.saturatingSub(requiredLPTValue);
    }

    // =============================
    // Internal NAV Synchronization and Yield Share Accrual Functions
    // =============================

    /**
     * @notice Synchronizes all tranche NAVs and the JT impermanent loss based on unrealized PNLs of the underlying investment(s)
     * @param _collateralNAV The current pure value of the coinvested collateral backing the senior and junior tranches
     * @param _twJTYieldShareAccruedWAD The currently accrued time-weighted JT yield share (JT YDM output) since the last premium payment, scaled to WAD precision
     * @param _twLPTYieldShareAccruedWAD The currently accrued time-weighted LPT yield share (LPT YDM output) since the last premium payment, scaled to WAD precision
     * @return state A struct containing all mark-to-market NAV, JT impermanent loss, LPT liquidity premium, and fee data after executing the sync
     * @return initialMarketState The initial state the market was in before the synchronization
     * @return premiumsPaid A boolean indicating whether the JT risk and LPT liquidity premiums were paid out of ST yield
     * @return jtImpermanentLossErased The amount of JT coverage loss erased (reset to 0)
     */
    function _previewSyncTrancheAccounting(
        NAV_UNIT _collateralNAV,
        uint256 _twJTYieldShareAccruedWAD,
        uint256 _twLPTYieldShareAccruedWAD
    )
        internal
        view
        returns (SyncedAccountingState memory state, MarketState initialMarketState, bool premiumsPaid, NAV_UNIT jtImpermanentLossErased)
    {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // The market state that this sync transitions from
        initialMarketState = $.lastMarketState;
        // Cache the last committed effective NAVs and JT impermanent loss: these are the running accumulators the waterfall settles against
        NAV_UNIT stEffectiveNAV = $.lastSTEffectiveNAV;
        NAV_UNIT jtEffectiveNAV = $.lastJTEffectiveNAV;
        NAV_UNIT jtImpermanentLoss = $.lastJTImpermanentLoss;
        // The liquidity premium and protocol fees accrued by this sync, settled by the mark-to-market step below
        NAV_UNIT lptLiquidityPremium;
        NAV_UNIT stProtocolFee;
        NAV_UNIT jtProtocolFee;
        NAV_UNIT lptProtocolFee;
        // Cache the dust tolerance: the attributed gain legs are pro-rata splits of the collateral NAV gain so it bounds their dust too
        NAV_UNIT dustTolerance = $.dustTolerance;
        // Cache the last committed collateral NAV: the reference the unrealized PNL since the last sync is measured against
        NAV_UNIT lastCollateralNAV = $.lastCollateralNAV;

        /// @dev STEP_APPLY_PNL_WATERFALL: Settle the collateral's unrealized PNL through the tranche waterfall: a gain repays the JT impermanent loss off the top and splits pro-rata across the restored claims, a loss is absorbed junior-first
        if (_collateralNAV < lastCollateralNAV) {
            // The unrealized loss of the underlying investment since the last NAV checkpoint
            NAV_UNIT loss = (lastCollateralNAV - _collateralNAV);

            /// @dev STEP_APPLY_JT_LOSS: JT's loss-absorption buffer takes the loss first, covering both its own share and ST's
            // The absorbed loss is impermanent: recoverable by future collateral gains through the repayment step
            NAV_UNIT jtImpermanentLossIncurred = RoycoUnitsMath.min(loss, jtEffectiveNAV);
            if (jtImpermanentLossIncurred != ZERO_NAV_UNITS) {
                jtEffectiveNAV = (jtEffectiveNAV - jtImpermanentLossIncurred);
                jtImpermanentLoss = (jtImpermanentLoss + jtImpermanentLossIncurred);
                loss = (loss - jtImpermanentLossIncurred);
            }

            /// @dev STEP_ST_INCURS_RESIDUAL_LOSSES: Apply any uncovered losses by JT to ST
            // The junior buffer is exhausted here and a loss is bounded by the checkpoint, which conservation keeps equal to the two claims, so the residual never underflows the senior claim
            if (loss != ZERO_NAV_UNITS) stEffectiveNAV = (stEffectiveNAV - loss);
        } else if (_collateralNAV > lastCollateralNAV) {
            // The unrealized gain of the underlying investment since the last NAV checkpoint
            NAV_UNIT gain = (_collateralNAV - lastCollateralNAV);

            /// @dev STEP_REPAY_JT_IMPERMANENT_LOSS: Any prior transient loss booked by the JT from coverage provided or its own loss is repaid first
            // The repayment is restoration, never yield, so it is never has a fee
            if (jtImpermanentLoss != ZERO_NAV_UNITS) {
                NAV_UNIT jtImpermanentLossRepayment = RoycoUnitsMath.min(gain, jtImpermanentLoss);
                jtImpermanentLoss = (jtImpermanentLoss - jtImpermanentLossRepayment);
                jtEffectiveNAV = (jtEffectiveNAV + jtImpermanentLossRepayment);
                gain = (gain - jtImpermanentLossRepayment);
                lastCollateralNAV = (lastCollateralNAV + jtImpermanentLossRepayment);
            }

            /// @dev STEP_APPLY_GAIN: Attribute the net gain to the ST and JT based on their ownership of the collateral NAV and apply them
            if (gain != ZERO_NAV_UNITS) {
                /// @dev STEP_ATTRIBUTE_RESIDUAL_GAIN: Attribute the residual gain to ST in proportion to its effective NAV claim on the collateral, which conservation keeps equal to stEffectiveNAV over lastCollateralNAV
                // Value marked from a zero collateral NAV has no live claims to split, so it accrues to the senior tranche first
                // The floor rounds in favor of juniors, routing the leftover wei into the junior residual
                NAV_UNIT stGain = ((lastCollateralNAV == ZERO_NAV_UNITS) ? gain : gain.mulDiv(stEffectiveNAV, lastCollateralNAV, Math.Rounding.Floor));
                NAV_UNIT jtGain = (gain - stGain);

                /// @dev STEP_APPLY_JT_GAIN: JT's attributed share of the residual gain is pure junior yield (the repayment step consumed the drawdown first)
                if (jtGain != ZERO_NAV_UNITS) {
                    // Compute the protocol fee taken on this JT yield accrual if it is not attributable to any rounding/dust
                    if (jtGain > dustTolerance) jtProtocolFee = jtGain.mulDiv($.jtProtocolFeeWAD, WAD, Math.Rounding.Floor);
                    // Book the gains to the JT
                    jtEffectiveNAV = (jtEffectiveNAV + jtGain);
                }

                /// @dev STEP_PAY_PREMIUMS: ST's attributed share of the residual gain is pure senior yield, used to pay the risk and liquidity premium to the JT and LPT respectively
                if (stGain != ZERO_NAV_UNITS) {
                    // Mark yield as distributed if the gain is not attributable to any rounding/dust
                    if (stGain > dustTolerance) premiumsPaid = true;
                    NAV_UNIT jtRiskPremium;
                    // The risk and liquidity premiums are always paid together, so they share a single elapsed window since the last premium payment
                    uint256 elapsedSinceLastPremiumPayments = (block.timestamp - $.lastPremiumPaymentTimestamp);
                    // If the last premium payments happened in the same block, use the instantaneous yield shares
                    // Else, use the time-weighted average yield shares since the last premium payments
                    if (elapsedSinceLastPremiumPayments == 0) {
                        // Set the elapsed time to 1 second (instantaneous)
                        elapsedSinceLastPremiumPayments = 1 seconds;
                        // Query the instantaneous yield shares for the JT and LPT
                        _twJTYieldShareAccruedWAD = Math.min(
                            IYDM($.jtYDM)
                                .previewYieldShare(
                                    initialMarketState,
                                    UtilizationLogic._computeCoverageUtilization($.lastCollateralNAV, $.minCoverageWAD, $.lastJTEffectiveNAV)
                                ),
                            $.maxJTYieldShareWAD
                        );
                        // The LPT YDM is driven by the market's liquidity utilization: the LPT liquidity premium scales with how utilized the LPT market-making inventory is
                        _twLPTYieldShareAccruedWAD = Math.min(
                            IYDM($.lptYDM)
                                .previewYieldShare(
                                    initialMarketState, UtilizationLogic._computeLiquidityUtilization($.lastSTEffectiveNAV, $.minLiquidityWAD, $.lastLPTRawNAV)
                                ),
                            $.maxLPTYieldShareWAD
                        );
                    }
                    // Compute the risk and liquidity premiums based on the yield shares and time elapsed since the last premium payments
                    jtRiskPremium = stGain.mulDiv(_twJTYieldShareAccruedWAD, (elapsedSinceLastPremiumPayments * WAD), Math.Rounding.Floor);
                    lptLiquidityPremium = stGain.mulDiv(_twLPTYieldShareAccruedWAD, (elapsedSinceLastPremiumPayments * WAD), Math.Rounding.Floor);
                    // The combined premiums can never exceed the senior gain: the JT and LPT yield shares are each capped so that they sum to at most 100% of senior appreciation
                    require((jtRiskPremium + lptLiquidityPremium) <= stGain, PREMIUMS_EXCEED_SENIOR_YIELD());
                    // Apply the risk premium to JT's effective NAV
                    if (jtRiskPremium != ZERO_NAV_UNITS) {
                        // Compute the protocol fee taken on the yield share accrual if it is not attributable to any rounding/dust
                        if (premiumsPaid) {
                            jtProtocolFee = (jtProtocolFee + jtRiskPremium.mulDiv($.jtYieldShareProtocolFeeWAD, WAD, Math.Rounding.Floor));
                        }
                        jtEffectiveNAV = (jtEffectiveNAV + jtRiskPremium);
                        stGain = (stGain - jtRiskPremium);
                    }
                    // Pay the liquidity premium to LPT: it is minted as senior shares to LPT, so it remains a senior claim within ST effective NAV (coverage-neutral) and is carved out of the residual only to size plain ST's retained yield and protocol fee
                    if (lptLiquidityPremium != ZERO_NAV_UNITS) {
                        // Compute the protocol fee taken on the yield share accrual if it is not attributable to any rounding/dust
                        if (premiumsPaid) {
                            lptProtocolFee = lptLiquidityPremium.mulDiv($.lptYieldShareProtocolFeeWAD, WAD, Math.Rounding.Floor);
                        }
                        stGain = (stGain - lptLiquidityPremium);
                    }
                    // Compute the protocol fee taken on this ST yield accrual if it is not attributable to any rounding/dust
                    if (premiumsPaid) stProtocolFee = stGain.mulDiv($.stProtocolFeeWAD, WAD, Math.Rounding.Floor);
                    // Book the residual gain to the ST, including the liquidity premium that remains a senior claim now owned by LPT (coverage neutral, so the two-term NAV conservation holds)
                    // The liquidity premium is used to mint ST shares to the LPT
                    stEffectiveNAV = (stEffectiveNAV + stGain + lptLiquidityPremium);
                }
            }
        }

        // Enforce the NAV conservation invariant
        require((_collateralNAV == (stEffectiveNAV + jtEffectiveNAV)), NAV_CONSERVATION_VIOLATION());

        /// @dev STEP_APPLY_MARKET_STATE_TRANSITION: Apply the market state transition resulting from this sync, then marshal the post-sync accounting state
        uint256 minCoverageWAD = $.minCoverageWAD;
        uint256 minLiquidityWAD = $.minLiquidityWAD;
        uint256 coverageLiquidationUtilizationWAD = $.coverageLiquidationUtilizationWAD;
        uint256 coverageUtilizationWAD = UtilizationLogic._computeCoverageUtilization(_collateralNAV, minCoverageWAD, jtEffectiveNAV);
        MarketState resultingMarketState;
        uint32 fixedTermEndTimestamp = $.fixedTermEndTimestamp;
        {
            uint256 fixedTermDurationSeconds = $.fixedTermDurationSeconds;
            // The market must be in a perpetual state if any of the following hold:
            // 1. The market is permanently perpetual (fixed-term duration 0), so it never enters a JT observation period
            // 2. The junior buffer is wiped (partially collateralized or a total wipe), so its dead restoration claim is extinguished, ST needs to be able to withdraw to avoid/book losses, and the YDM needs to kick in to reinstate proper collateralization
            // 3. The JT impermanent loss is within the dust tolerance (fully repaid or dust-sized), so JT provides its loss-absorption buffer and needs no observation period: dust ST or JT losses (eg. rounding in the underlying NAVs) never lock or keep locking the market
            // 4. The current fixed-term has elapsed, so the transient JT observation period is complete
            // 5. The coverage utilization breached the liquidation threshold, so the market forces open senior exits
            if (
                fixedTermDurationSeconds == 0 || jtEffectiveNAV == ZERO_NAV_UNITS || jtImpermanentLoss <= dustTolerance
                    || (initialMarketState == MarketState.FIXED_TERM && fixedTermEndTimestamp <= block.timestamp)
                    || coverageUtilizationWAD >= coverageLiquidationUtilizationWAD
            ) {
                // A perpetual commit always clears the JT impermanent loss ledger and the term, so a perpetual market never carries a drawdown
                jtImpermanentLossErased = jtImpermanentLoss;
                jtImpermanentLoss = ZERO_NAV_UNITS;
                // Transition to a perpetual state
                resultingMarketState = MarketState.PERPETUAL;
                fixedTermEndTimestamp = 0;
            } else {
                // A market is in fixed-term until the JT impermanent loss is completely restored
                // NOTE: The liquidity premium and all protocol fees are structurally zero here since JT IL needs to be zero for any fees to be taken
                resultingMarketState = MarketState.FIXED_TERM;
                // Only modify the fixed term's end timestamp if this sync transitioned the market into it
                if (initialMarketState == MarketState.PERPETUAL) fixedTermEndTimestamp = uint32(block.timestamp + fixedTermDurationSeconds);
            }
        }

        // Marshal the post-sync state and return it to the caller
        // NOTE: The liquidity provider tranche raw NAV and utilization are zero placeholders that the kernel refreshes after committing the fresh mark
        state = SyncedAccountingState({
            marketState: resultingMarketState,
            collateralNAV: _collateralNAV,
            lptRawNAV: ZERO_NAV_UNITS,
            stEffectiveNAV: stEffectiveNAV,
            jtEffectiveNAV: jtEffectiveNAV,
            jtImpermanentLoss: jtImpermanentLoss,
            lptLiquidityPremium: lptLiquidityPremium,
            stProtocolFee: stProtocolFee,
            jtProtocolFee: jtProtocolFee,
            lptProtocolFee: lptProtocolFee,
            coverageUtilizationWAD: coverageUtilizationWAD,
            liquidityUtilizationWAD: 0,
            fixedTermEndTimestamp: fixedTermEndTimestamp,
            minCoverageWAD: minCoverageWAD,
            coverageLiquidationUtilizationWAD: coverageLiquidationUtilizationWAD,
            minLiquidityWAD: minLiquidityWAD
        });
    }

    /**
     * @notice Accrues the JT and LPT yield shares since the last premium payment
     * @dev Advances the adaptive YDMs and gets the instantaneous yield shares, each capped at its configured maximum, then weights them by the time elapsed since the last accrual
     * @return twJTYieldShareAccruedWAD The updated time-weighted JT yield share since the last premium payment
     * @return twLPTYieldShareAccruedWAD The updated time-weighted LPT yield share since the last premium payment
     */
    function _accruePremiumYieldShares() internal returns (uint128 twJTYieldShareAccruedWAD, uint128 twLPTYieldShareAccruedWAD) {
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
        if (elapsed == 0) return ($.twJTYieldShareAccruedWAD, $.twLPTYieldShareAccruedWAD);

        // Advance the adaptive YDMs and read each instantaneous yield share, capped at its configured maximum
        (uint256 coverageUtilizationWAD, uint256 liquidityUtilizationWAD) = _computeUtilizations();
        uint256 jtYieldShareWAD = Math.min(IYDM($.jtYDM).yieldShare($.lastMarketState, coverageUtilizationWAD), $.maxJTYieldShareWAD);
        uint256 lptYieldShareWAD = Math.min(IYDM($.lptYDM).yieldShare($.lastMarketState, liquidityUtilizationWAD), $.maxLPTYieldShareWAD);

        // Accrue the time-weighted yield shares since the last tranche interaction
        twJTYieldShareAccruedWAD = ($.twJTYieldShareAccruedWAD += uint128(jtYieldShareWAD * elapsed));
        twLPTYieldShareAccruedWAD = ($.twLPTYieldShareAccruedWAD += uint128(lptYieldShareWAD * elapsed));
        $.lastYieldShareAccrualTimestamp = uint32(block.timestamp);

        emit YieldSharesAccrued(jtYieldShareWAD, twJTYieldShareAccruedWAD, lptYieldShareWAD, twLPTYieldShareAccruedWAD);
    }

    /**
     * @notice Computes and returns the currently accrued JT and LPT yield shares since the last premium payment
     * @dev Gets the instantaneous yield shares, each capped at its configured maximum, and weights them by the time elapsed since the last accrual
     * @return twJTYieldShareAccruedWAD The updated time-weighted JT yield share since the last premium payment
     * @return twLPTYieldShareAccruedWAD The updated time-weighted LPT yield share since the last premium payment
     */
    function _previewPremiumYieldShareAccrual() internal view returns (uint128 twJTYieldShareAccruedWAD, uint128 twLPTYieldShareAccruedWAD) {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $.lastYieldShareAccrualTimestamp;
        if (lastUpdate == 0) return (0, 0);

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return ($.twJTYieldShareAccruedWAD, $.twLPTYieldShareAccruedWAD);

        // Read each instantaneous yield share, capped at its configured maximum
        (uint256 coverageUtilizationWAD, uint256 liquidityUtilizationWAD) = _computeUtilizations();
        uint256 jtYieldShareWAD = Math.min(IYDM($.jtYDM).previewYieldShare($.lastMarketState, coverageUtilizationWAD), $.maxJTYieldShareWAD);
        uint256 lptYieldShareWAD = Math.min(IYDM($.lptYDM).previewYieldShare($.lastMarketState, liquidityUtilizationWAD), $.maxLPTYieldShareWAD);

        // Apply the accrual of the yield shares to the accumulators, weighted by the time elapsed
        twJTYieldShareAccruedWAD = ($.twJTYieldShareAccruedWAD + uint128(jtYieldShareWAD * elapsed));
        twLPTYieldShareAccruedWAD = ($.twLPTYieldShareAccruedWAD + uint128(lptYieldShareWAD * elapsed));
    }

    /**
     * @notice Computes and returns the coverage and liquidity utilizations
     * @return coverageUtilizationWAD The coverage utilization driving the JT risk premium, scaled to WAD precision
     * @return liquidityUtilizationWAD The liquidity utilization driving the LPT liquidity premium, scaled to WAD precision
     */
    function _computeUtilizations() private view returns (uint256 coverageUtilizationWAD, uint256 liquidityUtilizationWAD) {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // Compute both utilizations
        coverageUtilizationWAD = UtilizationLogic._computeCoverageUtilization($.lastCollateralNAV, $.minCoverageWAD, $.lastJTEffectiveNAV);
        liquidityUtilizationWAD = UtilizationLogic._computeLiquidityUtilization($.lastSTEffectiveNAV, $.minLiquidityWAD, $.lastLPTRawNAV);
    }

    // =============================
    // Administrative Functions
    // =============================

    /// @inheritdoc IRoycoDayAccountant
    function setJuniorTrancheYDM(address _jtYDM, bytes calldata _jtYDMInitializationData) external override(IRoycoDayAccountant) restricted {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // The junior and liquidity provider tranche YDMs must remain distinct: a shared instance would corrupt both premiums by interleaving coverage and liquidity driven updates
        require(_jtYDM != $.lptYDM, YDMS_CANNOT_BE_IDENTICAL());
        // Best-effort sync to settle unrealized PNL under the outgoing JT YDM
        // NOTE: A reverting sync is tolerated since this setter is the only recovery path from a sync-bricking JT YDM
        KERNEL.call(abi.encodeCall(IRoycoDayKernel.syncTrancheAccounting, ()));
        // Initialize and set the new JT YDM for this market
        _initializeYDM(_jtYDM, _jtYDMInitializationData);
        $.jtYDM = _jtYDM;
        emit JuniorTrancheYDMUpdated(_jtYDM);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setLiquidityProviderTrancheYDM(address _lptYDM, bytes calldata _lptYDMInitializationData) external override(IRoycoDayAccountant) restricted {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // The junior and liquidity provider tranche YDMs must remain distinct: a shared instance would corrupt both premiums by interleaving coverage and liquidity driven updates
        require(_lptYDM != $.jtYDM, YDMS_CANNOT_BE_IDENTICAL());
        // Best-effort sync to settle unrealized PNL under the outgoing LPT YDM
        // NOTE: A reverting sync is tolerated since this setter is the only recovery path from a sync-bricking LPT YDM
        KERNEL.call(abi.encodeCall(IRoycoDayKernel.syncTrancheAccounting, ()));
        // Initialize and set the new LPT YDM for this market
        _initializeYDM(_lptYDM, _lptYDMInitializationData);
        $.lptYDM = _lptYDM;
        emit LiquidityProviderTrancheYDMUpdated(_lptYDM);
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
    function setLPTYieldShareProtocolFee(uint64 _lptYieldShareProtocolFeeWAD) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        // Ensure that the protocol fee percentage is valid
        require(_lptYieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        _getRoycoDayAccountantStorage().lptYieldShareProtocolFeeWAD = _lptYieldShareProtocolFeeWAD;
        emit LiquidityProviderTrancheYieldShareProtocolFeeUpdated(_lptYieldShareProtocolFeeWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setMinCoverage(uint64 _minCoverageWAD) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // The coverage requirement must leave headroom for the junior tranche to provide coverage (the liquidation threshold is unchanged and already valid)
        require(_minCoverageWAD < WAD, INVALID_COVERAGE_CONFIG());
        $.minCoverageWAD = _minCoverageWAD;
        emit CoverageUpdated(_minCoverageWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setLiquidationCoverageUtilization(uint256 _coverageLiquidationUtilizationWAD)
        external
        override(IRoycoDayAccountant)
        restricted
        withSyncedAccounting
    {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // The liquidation coverageUtilization threshold can only be breachable once the NAVs have experienced losses (the minimum coverage is unchanged and already valid)
        require(_coverageLiquidationUtilizationWAD > WAD, INVALID_COVERAGE_CONFIG());
        $.coverageLiquidationUtilizationWAD = _coverageLiquidationUtilizationWAD;
        emit LiquidationCoverageUtilizationUpdated(_coverageLiquidationUtilizationWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setMinLiquidity(uint64 _minLiquidityWAD) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        // The liquidity requirement must leave headroom (minLiquidity < WAD)
        require(_minLiquidityWAD < WAD, INVALID_LIQUIDITY_CONFIG());
        _getRoycoDayAccountantStorage().minLiquidityWAD = _minLiquidityWAD;
        emit LiquidityUpdated(_minLiquidityWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setMaxYieldShares(uint64 _maxJTYieldShareWAD, uint64 _maxLPTYieldShareWAD) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        // Validate the new yield share configuration: the maximum JT and LPT yield shares must sum to at most 100% of senior appreciation
        _validateYieldShareConfig(_maxJTYieldShareWAD, _maxLPTYieldShareWAD);
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        $.maxJTYieldShareWAD = _maxJTYieldShareWAD;
        $.maxLPTYieldShareWAD = _maxLPTYieldShareWAD;
        emit MaxYieldSharesUpdated(_maxJTYieldShareWAD, _maxLPTYieldShareWAD);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setFixedTermDuration(uint24 _fixedTermDurationSeconds) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        $.fixedTermDurationSeconds = _fixedTermDurationSeconds;
        // If the specified duration is 0, the market will permanently be in a perpetual state
        if (_fixedTermDurationSeconds == 0) {
            emit JuniorTrancheImpermanentLossReset($.lastJTImpermanentLoss);
            $.lastJTImpermanentLoss = ZERO_NAV_UNITS;
            $.lastMarketState = MarketState.PERPETUAL;
            // Reset the fixed-term end timestamp
            delete $.fixedTermEndTimestamp;
        }
        emit FixedTermDurationUpdated(_fixedTermDurationSeconds);
    }

    /// @inheritdoc IRoycoDayAccountant
    function setDustTolerance(NAV_UNIT _dustTolerance) external override(IRoycoDayAccountant) restricted withSyncedAccounting {
        _getRoycoDayAccountantStorage().dustTolerance = _dustTolerance;
        emit DustToleranceUpdated(_dustTolerance);
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Validates the yield share (premium) parameters of the market
     * @param _maxJTYieldShareWAD The maximum JT yield share (risk premium) as a percentage of senior appreciation, scaled to WAD precision
     * @param _maxLPTYieldShareWAD The maximum LPT yield share (liquidity premium) as a percentage of senior appreciation, scaled to WAD precision
     */
    function _validateYieldShareConfig(uint64 _maxJTYieldShareWAD, uint64 _maxLPTYieldShareWAD) internal pure {
        // The combined maximum yield shares cannot exceed 100% of senior appreciation, so the risk and liquidity premiums always fit within the senior gain
        require((_maxJTYieldShareWAD + _maxLPTYieldShareWAD) <= WAD, INVALID_MAX_YIELD_SHARE_CONFIG());
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
