// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { RoycoBase } from "../../base/RoycoBase.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoDayAccountant } from "../../interfaces/accountant/IRoycoDayAccountant.sol";
import { MAX_NAV_UNITS, MAX_PROTOCOL_FEE_WAD, WAD, ZERO_NAV_UNITS } from "../../libraries/Constants.sol";
import { MarketState, NAV_UNIT, Operation, SyncedAccountingState } from "../../libraries/Types.sol";
import { Math, RoycoUnitsMath, toNAVUnits } from "../../libraries/Units.sol";
import { UtilizationLogic } from "../../libraries/logic/UtilizationLogic.sol";

/**
 * @title RoycoDayAccountant
 * @author Shivaansh Kapoor, Ankur Dubey, Tomer Ganor
 * @notice Abstract base carrying the attribution-independent accounting, coverage, and liquidity operations and requirements for a Royco market
 * @notice Responsible for the operation-driven NAV commits, the coverage and liquidity bounds, and the shared market configuration, while the concrete accountant supplies the PNL attribution
 */
abstract contract RoycoDayAccountant is IRoycoDayAccountant, RoycoBase {
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for uint256;

    /// @dev Storage slot for RoycoDayAccountantState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoDayAccountantState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _ROYCO_DAY_ACCOUNTANT_STORAGE_SLOT = 0x3eb9440b0208b8d20dc454b361ed9d3f272aa9a4fb2bcc89d823d3b8e5663200;

    /// @dev Permissions the function to only be callable by the market's kernel
    /// @dev Should be placed on all state mutating NAV synchronization functions
    modifier onlyRoycoKernel() {
        require(msg.sender == _getRoycoDayAccountantStorage().kernel, ONLY_ROYCO_KERNEL());
        _;
    }

    /// @dev Synchronizes the market's accounting to reconcile unrealized PNL at the start of the call
    /// @dev Ensures that any parameter changes to the coverage or liquidity configurations are safe
    modifier withSyncedAccounting() {
        address kernel = _getRoycoDayAccountantStorage().kernel;
        // Cache the state of the accountant after the pre-operation accounting synchronization
        SyncedAccountingState memory preOp = IRoycoDayKernel(kernel).syncTrancheAccountingFromAccountant();
        _;
        // Retrieve the result of the accounting synchronization after the paramter change
        SyncedAccountingState memory postOp = IRoycoDayKernel(kernel).syncTrancheAccountingFromAccountant();
        // Check that the coverage utilization is at most 100% or it didn't increase/worsen
        // Check that the coverage liquidation utilization didn't get worse or this parameter change did not send the market into a liquidation state
        require(
            (postOp.coverageUtilizationWAD <= WAD || (postOp.coverageUtilizationWAD <= preOp.coverageUtilizationWAD))
                && ((preOp.coverageLiquidationUtilizationWAD <= postOp.coverageLiquidationUtilizationWAD)
                    || (postOp.coverageLiquidationUtilizationWAD > postOp.coverageUtilizationWAD)),
            INVALID_COVERAGE_CONFIG()
        );
        // Check that the liquidity utilization is at most 100% or it didn't increase/worsen
        require(postOp.liquidityUtilizationWAD <= WAD || (postOp.liquidityUtilizationWAD <= preOp.liquidityUtilizationWAD), INVALID_LIQUIDITY_CONFIG());
    }

    // =============================
    // Initialization Functions
    // =============================

    /**
     * @notice Initializes the base Royco accountant state
     * @dev Initializes any parent contracts and the base accountant state
     * @param _params The standard initialization parameters for the Royco accountant
     */
    function __RoycoDayAccountant_init(RoycoDayAccountantInitParams memory _params) internal onlyInitializing {
        // Initialize the base state of the accountant
        __RoycoBase_init(_params.initialAuthority);

        // Validate the accountant initialization parameters
        // Ensure that the kernel is not null
        require(_params.kernel != address(0), NULL_ADDRESS());
        // Ensure that the protocol fee percentages are valid
        require(
            _params.stProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD && _params.jtProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD
                && _params.jtYieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD && _params.lptYieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD,
            MAX_PROTOCOL_FEE_EXCEEDED()
        );
        // Ensure that the coverage requirement must require less coverage than the entire senior exposure and the liquidation coverage utilization threshold can only be breached once the NAVs have experienced losses
        require(_params.minCoverageWAD < WAD && _params.coverageLiquidationUtilizationWAD > WAD, INVALID_COVERAGE_CONFIG());
        // Ensure that the liquidity requirement must require less market-making depth than the entire senior tranche claims
        require(_params.minLiquidityWAD < WAD, INVALID_LIQUIDITY_CONFIG());

        // Initialize the accountant state
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
        $.minLiquidityWAD = _params.minLiquidityWAD;
        $.fixedTermDurationSeconds = _params.fixedTermDurationSeconds;
        emit MinCoverageUpdated(_params.minCoverageWAD);
        emit MinLiquidityUpdated(_params.minLiquidityWAD);
        emit FixedTermDurationUpdated(_params.fixedTermDurationSeconds);

        // Set the fields in slot 2 of storage
        $.kernel = _params.kernel;
        $.fixedTermCommenceableAtTimestamp = uint64(block.timestamp + _params.fixedTermGracePeriodSeconds);
        emit FixedTermCommenceableAt($.fixedTermCommenceableAtTimestamp);

        // Set the rest of the fields
        $.coverageLiquidationUtilizationWAD = _params.coverageLiquidationUtilizationWAD;
        $.dustTolerance = _params.dustTolerance;
        emit LiquidationCoverageUtilizationUpdated(_params.coverageLiquidationUtilizationWAD);
        emit DustToleranceUpdated(_params.dustTolerance);
    }

    // =============================
    // NAV Synchronization Functions
    // =============================

    /// @inheritdoc IRoycoDayAccountant
    function commitLiquidityProviderTrancheRawNAV(NAV_UNIT _freshLPTRawNAV) external override(IRoycoDayAccountant) onlyRoycoKernel {
        // Commit the freshly marked liquidity provider tranche raw NAV: the kernel marks it after the sync commits the senior/junior NAVs and mints any fee shares
        // The LPT raw NAV is dependent on the fresh ST share price which is resolved on the preceding pre-op synchronization
        _getRoycoDayAccountantStorage().lastLPTRawNAV = _freshLPTRawNAV;
        emit LPTRawNAVCommitted(_freshLPTRawNAV);
    }

    /// @inheritdoc IRoycoDayAccountant
    function postOpSyncTrancheAccounting(
        Operation _op,
        NAV_UNIT _collateralNAV,
        NAV_UNIT _lptRawNAV,
        NAV_UNIT _stSelfLiquidationBonusNAV
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
        } else if (_op == Operation.ST_REDEMPTION) {
            // A senior redemption leaves the liquidity provider tranche mark untouched and always redeems collateral value
            require(deltaCollateralNAV < 0 && deltaLPTRawNAV == 0, INVALID_POST_OP_STATE(_op));
            // Reduce JT effective NAV by the bonus provided from its assets
            jtEffectiveNAV = (jtEffectiveNAV - _stSelfLiquidationBonusNAV);
            // Reduce ST effective NAV by the total redemptions without the bonus provided from JT effective NAV
            stEffectiveNAV = (stEffectiveNAV - (toNAVUnits(-deltaCollateralNAV) - _stSelfLiquidationBonusNAV));
        } else if (_op == Operation.JT_DEPOSIT) {
            require(deltaCollateralNAV > 0 && deltaLPTRawNAV == 0 && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
            // New JT deposits are treated as an addition to the future loss-absorption buffer
            jtEffectiveNAV = (jtEffectiveNAV + toNAVUnits(deltaCollateralNAV));
        } else if (_op == Operation.JT_REDEMPTION) {
            // JT cannot get a bonus from its own NAV, and a junior redemption leaves the senior exposure and supply untouched so it cannot move the liquidity provider tranche mark
            require(deltaCollateralNAV < 0 && deltaLPTRawNAV == 0 && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
            // The actual amount withdrawn from JT effective NAV could be from both tranches (its own share of its NAV, ST yield share, IL repayments, etc.)
            jtEffectiveNAV = (jtEffectiveNAV - toNAVUnits(-deltaCollateralNAV));
        } else if (_op == Operation.LPT_DEPOSIT) {
            // An in-kind LPT deposit only adds market-making inventory, the collateral cannot move
            require(deltaLPTRawNAV > 0 && deltaCollateralNAV == 0 && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
        } else if (_op == Operation.LPT_REDEMPTION) {
            // An in-kind LPT redemption only transfers out market-making inventory and idle premium shares, the collateral cannot move and no bonus is paid
            require(deltaLPTRawNAV < 0 && deltaCollateralNAV == 0 && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
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
    // Administrative Functions
    // =============================

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
        emit MinCoverageUpdated(_minCoverageWAD);
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
        emit MinLiquidityUpdated(_minLiquidityWAD);
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
     * @notice Computes and returns the coverage and liquidity utilizations
     * @return coverageUtilizationWAD The coverage utilization driving the JT risk premium, scaled to WAD precision
     * @return liquidityUtilizationWAD The liquidity utilization driving the LPT liquidity premium, scaled to WAD precision
     */
    function _computeUtilizations() internal view returns (uint256 coverageUtilizationWAD, uint256 liquidityUtilizationWAD) {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // Compute both utilizations
        coverageUtilizationWAD = UtilizationLogic._computeCoverageUtilization($.lastCollateralNAV, $.minCoverageWAD, $.lastJTEffectiveNAV);
        liquidityUtilizationWAD = UtilizationLogic._computeLiquidityUtilization($.lastSTEffectiveNAV, $.minLiquidityWAD, $.lastLPTRawNAV);
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
            $.slot := _ROYCO_DAY_ACCOUNTANT_STORAGE_SLOT
        }
    }
}
