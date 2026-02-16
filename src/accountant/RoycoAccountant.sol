// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoAccountant } from "../interfaces/IRoycoAccountant.sol";
import { IYDM } from "../interfaces/IYDM.sol";
import { IRoycoKernel } from "../interfaces/kernel/IRoycoKernel.sol";
import { MAX_PROTOCOL_FEE_WAD, MIN_COVERAGE_WAD, WAD, ZERO_NAV_UNITS } from "../libraries/Constants.sol";
import { MarketState, NAV_UNIT, Operation, SyncedAccountingState } from "../libraries/Types.sol";
import { UnitsMathLib, toNAVUnits, toUint256 } from "../libraries/Units.sol";
import { Math, UtilsLib } from "../libraries/UtilsLib.sol";

/**
 * @title RoycoAccountant
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Performs and tracks the core accounting operations for a Royco market
 * @notice Responsible for marking tranche NAVs to market, tracking impermanent losses, distributing yield via the YDM, and computing protocol fees
 * @notice Responsible for tracking the operational and coverage state of the Royco market
 */
contract RoycoAccountant is IRoycoAccountant, RoycoBase {
    using Math for uint256;
    using UnitsMathLib for NAV_UNIT;

    /// @dev Storage slot for RoycoAccountantState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoAccountantState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_ACCOUNTANT_STORAGE_SLOT = 0xc8240830e1172c6f1489139d8edb11776c3d3b2f893e3f4ce0fb541305a63a00;

    /// @dev Enforces that the function is called by the accountant's Royco kernel
    /// forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier onlyRoycoKernel() {
        require(msg.sender == _getRoycoAccountantStorage().kernel, ONLY_ROYCO_KERNEL());
        _;
    }

    /// @dev Enforces that the kernel's accounting is synced before the function is called
    /// forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier withSyncedAccounting() {
        IRoycoKernel(_getRoycoAccountantStorage().kernel).syncTrancheAccounting();
        _;
    }

    /**
     * @notice Initializes the Royco accountant state
     * @param _params The initialization parameters for the Royco accountant
     * @param _initialAuthority The initial authority for the Royco accountant
     */
    function initialize(RoycoAccountantInitParams calldata _params, address _initialAuthority) external initializer {
        // Initialize the base state of the accountant
        __RoycoBase_init(_initialAuthority);

        // Ensure that the protocol fee percentage is valid
        require(_params.stProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD && _params.jtProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        // Validate the market's inital coverage configuration
        _validateCoverageConfig(_params.coverageWAD, _params.betaWAD, _params.lltvWAD);
        // Initialize the YDM for this market
        _initializeYDM(_params.ydm, _params.ydmInitializationData);

        // Initialize the state of the accountant
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        $.kernel = _params.kernel;
        $.lltvWAD = _params.lltvWAD;
        emit LLTVUpdated(_params.lltvWAD);
        $.fixedTermDurationSeconds = _params.fixedTermDurationSeconds;
        emit FixedTermDurationUpdated(_params.fixedTermDurationSeconds);
        $.stProtocolFeeWAD = _params.stProtocolFeeWAD;
        emit SeniorTrancheProtocolFeeUpdated(_params.stProtocolFeeWAD);
        $.jtProtocolFeeWAD = _params.jtProtocolFeeWAD;
        emit JuniorTrancheProtocolFeeUpdated(_params.jtProtocolFeeWAD);
        $.coverageWAD = _params.coverageWAD;
        emit CoverageUpdated(_params.coverageWAD);
        $.betaWAD = _params.betaWAD;
        emit BetaUpdated(_params.betaWAD);
        $.ydm = _params.ydm;
        emit YDMUpdated(_params.ydm);
        $.stNAVDustTolerance = _params.stNAVDustTolerance;
        emit SeniorTrancheDustToleranceUpdated(_params.stNAVDustTolerance);
        $.jtNAVDustTolerance = _params.jtNAVDustTolerance;
        emit JuniorTrancheDustToleranceUpdated(_params.jtNAVDustTolerance);
    }

    /// @inheritdoc IRoycoAccountant
    function preOpSyncTrancheAccounting(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV
    )
        public
        override(IRoycoAccountant)
        onlyRoycoKernel
        returns (SyncedAccountingState memory state)
    {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Preview synchronization of the tranche NAVs and impermanent losses
        MarketState initialMarketState;
        bool yieldDistributed;
        NAV_UNIT jtCoverageImpermanentLossErased;
        (state, initialMarketState, yieldDistributed, jtCoverageImpermanentLossErased) =
            _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _accrueJTYieldShare());

        // ST yield was split between ST and JT
        if (yieldDistributed) {
            // Reset the accumulator and update the last yield distribution timestamp
            delete $.twJTYieldShareAccruedWAD;
            $.lastDistributionTimestamp = uint32(block.timestamp);
        }

        // Checkpoint the resulting market state, mark to market NAVs, and impermanent losses
        $.lastMarketState = state.marketState;
        $.lastSTRawNAV = _stRawNAV;
        $.lastJTRawNAV = _jtRawNAV;
        $.lastSTEffectiveNAV = state.stEffectiveNAV;
        $.lastJTEffectiveNAV = state.jtEffectiveNAV;
        $.lastSTImpermanentLoss = state.stImpermanentLoss;
        $.lastJTCoverageImpermanentLoss = state.jtCoverageImpermanentLoss;
        $.lastJTSelfImpermanentLoss = state.jtSelfImpermanentLoss;

        // If the market transitioned from a perpetual to a fixed term state, set the end timestamp of the fixed term
        if (initialMarketState == MarketState.PERPETUAL && state.marketState == MarketState.FIXED_TERM) {
            $.fixedTermEndTimestamp = state.fixedTermEndTimestamp;
            emit FixedTermCommenced(state.fixedTermEndTimestamp);
        }

        // If the JT Coverage IL was erased, signal the resetting
        if (jtCoverageImpermanentLossErased != ZERO_NAV_UNITS) {
            emit JTCoverageImpermanentLossErased(jtCoverageImpermanentLossErased);
        }

        emit TrancheAccountingSynced(state);
    }

    /// @inheritdoc IRoycoAccountant
    function previewSyncTrancheAccounting(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV
    )
        public
        view
        override(IRoycoAccountant)
        returns (SyncedAccountingState memory state)
    {
        (state,,,) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _previewJTYieldShareAccrual());
    }

    /// @inheritdoc IRoycoAccountant
    function postOpSyncTrancheAccounting(
        Operation _op,
        NAV_UNIT _stPostOpRawNAV,
        NAV_UNIT _jtPostOpRawNAV,
        NAV_UNIT _stDepositPreOpNAV,
        NAV_UNIT _jtDepositPreOpNAV,
        NAV_UNIT _stRedeemPreOpNAV,
        NAV_UNIT _jtRedeemPreOpNAV
    )
        public
        override(IRoycoAccountant)
        onlyRoycoKernel
        returns (SyncedAccountingState memory state)
    {
        // For deposits, either ST or JT can deposit and increase the NAV (not both)
        // For withdrawals, ST and/or JT NAV can be withdrawn (coverage applied, yield sharing, IL repayments, etc.)
        // A simultaneous deposit and withdrawal is impossible
        // Liquidation is a special case that bypasses this validation
        require(
            _op == Operation.LIQUIDATION
                || ((_stDepositPreOpNAV > ZERO_NAV_UNITS ? 1 : 0) + (_jtDepositPreOpNAV > ZERO_NAV_UNITS ? 1 : 0)
                            + ((_stRedeemPreOpNAV > ZERO_NAV_UNITS || _jtRedeemPreOpNAV > ZERO_NAV_UNITS) ? 1 : 0)) == 1,
            INVALID_POST_OP_STATE(_op)
        );

        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Cache the last checkpointed market state, effective NAV, and impermanent losses for each tranche
        NAV_UNIT stRawNAV = $.lastSTRawNAV;
        NAV_UNIT jtRawNAV = $.lastJTRawNAV;
        NAV_UNIT jtEffectiveNAV = $.lastJTEffectiveNAV;
        NAV_UNIT stEffectiveNAV = $.lastSTEffectiveNAV;
        NAV_UNIT stImpermanentLoss = $.lastSTImpermanentLoss;
        NAV_UNIT jtCoverageImpermanentLoss = $.lastJTCoverageImpermanentLoss;
        NAV_UNIT jtSelfImpermanentLoss = $.lastJTSelfImpermanentLoss;

        // Apply the effects of the operation that was executed
        if (_op == Operation.LIQUIDATION) {
            // Liquidation: raw NAVs set directly from post-op values (includes all withdrawals: demanded + bonus)
            // ST effective NAV unchanged (liquidation settlement compensates demanded assets)
            // JT effective NAV decreases by bonus (penalty for allowing position to become underwater)
            stRawNAV = _stPostOpRawNAV;
            jtRawNAV = _jtPostOpRawNAV;

            // Bonus NAV = NAV of bonus from ST assets + NAV of bonus from JT assets
            NAV_UNIT bonusNAV = _stRedeemPreOpNAV + _jtRedeemPreOpNAV;
            if (bonusNAV != ZERO_NAV_UNITS) {
                NAV_UNIT preLiquidationJTEffectiveNAV = jtEffectiveNAV;
                jtEffectiveNAV = preLiquidationJTEffectiveNAV - bonusNAV;

                // Scale JT impermanent losses proportionally for JT's loss from paying the liquidation bonus
                if (jtCoverageImpermanentLoss != ZERO_NAV_UNITS) {
                    jtCoverageImpermanentLoss = jtCoverageImpermanentLoss.mulDiv(jtEffectiveNAV, preLiquidationJTEffectiveNAV, Math.Rounding.Floor);
                }
                if (jtSelfImpermanentLoss != ZERO_NAV_UNITS && $.lastJTRawNAV != ZERO_NAV_UNITS) {
                    jtSelfImpermanentLoss = jtSelfImpermanentLoss.mulDiv(jtRawNAV, $.lastJTRawNAV, Math.Rounding.Floor);
                }
            }
        } else if (_op == Operation.ST_DEPOSIT) {
            require(_stDepositPreOpNAV > ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
            // The raw NAV is meant to be increased by the ST NAV deposited
            stRawNAV = stRawNAV + _stDepositPreOpNAV;
            // New ST deposits are treated as an addition to the future ST exposure
            stEffectiveNAV = stEffectiveNAV + _stDepositPreOpNAV;
        } else if (_op == Operation.JT_DEPOSIT) {
            require(_jtDepositPreOpNAV > ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
            // The raw NAV is meant to be increased by the JT NAV deposited
            jtRawNAV = jtRawNAV + _jtDepositPreOpNAV;
            // New JT deposits are treated as an addition to the future loss-absorption buffer
            jtEffectiveNAV = jtEffectiveNAV + _jtDepositPreOpNAV;
        } else {
            require(_stRedeemPreOpNAV > ZERO_NAV_UNITS || _jtRedeemPreOpNAV > ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));

            // The raw NAVs are meant to be decreased by the NAV withdrawn from each tranche
            if (_stRedeemPreOpNAV != ZERO_NAV_UNITS) stRawNAV = stRawNAV - _stRedeemPreOpNAV;
            if (_jtRedeemPreOpNAV != ZERO_NAV_UNITS) jtRawNAV = jtRawNAV - _jtRedeemPreOpNAV;

            if (_op == Operation.ST_REDEEM) {
                NAV_UNIT preWithdrawalSTEffectiveNAV = stEffectiveNAV;
                // The actual amount withdrawn from ST effective NAV could be from both tranches (its own share of its NAV, coverage applied, IL repayments, etc.)
                stEffectiveNAV = preWithdrawalSTEffectiveNAV - (_stRedeemPreOpNAV + _jtRedeemPreOpNAV);
                // The withdrawing senior LP has realized its proportional share of past uncovered losses and associated recovery optionality, rounding in favor of senior
                if (stImpermanentLoss != ZERO_NAV_UNITS) {
                    stImpermanentLoss = stImpermanentLoss.mulDiv(stEffectiveNAV, preWithdrawalSTEffectiveNAV, Math.Rounding.Ceil);
                }
                // The withdrawing senior LP has realized its proportional share of past JT losses from coverage applied and its associated recovery optionality, rounding in favor of senior
                if (jtCoverageImpermanentLoss != ZERO_NAV_UNITS) {
                    jtCoverageImpermanentLoss = jtCoverageImpermanentLoss.mulDiv(stEffectiveNAV, preWithdrawalSTEffectiveNAV, Math.Rounding.Floor);
                }
                // JT raw NAV that is leaving the market realized its proportional share of past JT losses from its own depreciation, rounding in favor of senior
                // If last JT raw NAV is zero, none of the JT exposure is leaving the market, so it is still entitled to 100% of it's self inflicted impermanent loss.
                if (jtSelfImpermanentLoss != ZERO_NAV_UNITS && $.lastJTRawNAV != ZERO_NAV_UNITS) {
                    jtSelfImpermanentLoss = jtSelfImpermanentLoss.mulDiv(jtRawNAV, $.lastJTRawNAV, Math.Rounding.Floor);
                }
            } else if (_op == Operation.JT_REDEEM) {
                NAV_UNIT preWithdrawalJTEffectiveNAV = jtEffectiveNAV;
                // The actual amount withdrawn from JT effective NAV could be from both tranches (its own share of its NAV, ST yield share, IL repayments, etc.)
                jtEffectiveNAV = preWithdrawalJTEffectiveNAV - (_stRedeemPreOpNAV + _jtRedeemPreOpNAV);
                // The withdrawing junior LP has realized its proportional share of past losses from coverage provided and associated recovery optionality, rounding in favor of senior
                if (jtCoverageImpermanentLoss != ZERO_NAV_UNITS) {
                    jtCoverageImpermanentLoss = jtCoverageImpermanentLoss.mulDiv(jtEffectiveNAV, preWithdrawalJTEffectiveNAV, Math.Rounding.Floor);
                }
                // JT raw NAV that is leaving the market realized its proportional share of past JT losses from its own depreciation, rounding in favor of senior
                // If last JT raw NAV is zero, none of the JT exposure is leaving the market, so it is still entitled to 100% of it's self inflicted impermanent loss.
                if (jtSelfImpermanentLoss != ZERO_NAV_UNITS && $.lastJTRawNAV != ZERO_NAV_UNITS) {
                    jtSelfImpermanentLoss = jtSelfImpermanentLoss.mulDiv(jtRawNAV, $.lastJTRawNAV, Math.Rounding.Floor);
                }
            }
        }

        // Checkpoint the mark to market NAVs and impermanent losses
        $.lastSTRawNAV = stRawNAV;
        $.lastJTRawNAV = jtRawNAV;
        $.lastSTEffectiveNAV = stEffectiveNAV;
        $.lastJTEffectiveNAV = jtEffectiveNAV;
        $.lastSTImpermanentLoss = stImpermanentLoss;
        $.lastJTCoverageImpermanentLoss = jtCoverageImpermanentLoss;
        $.lastJTSelfImpermanentLoss = jtSelfImpermanentLoss;

        // If any additional delta exists in the total raw and effective NAVs, it can attributed to rounding/dust losses in NAV: these must be treated as underlying PNL
        int256 totalNAVDelta = UnitsMathLib.computeNAVDelta((_stPostOpRawNAV + _jtPostOpRawNAV), (stEffectiveNAV + jtEffectiveNAV));
        if (totalNAVDelta != 0) return preOpSyncTrancheAccounting(_stPostOpRawNAV, _jtPostOpRawNAV);

        // NAV conservation is preserved: marshal the post-sync state and return
        state = SyncedAccountingState({
            // No state transition is possible in this branch since there is no PNL and NAV changes enforce coverage (ensuring LLTV can't be breached if it wasn't already in pre-op sync)
            marketState: $.lastMarketState,
            stRawNAV: _stPostOpRawNAV,
            jtRawNAV: _jtPostOpRawNAV,
            stEffectiveNAV: stEffectiveNAV,
            jtEffectiveNAV: jtEffectiveNAV,
            stImpermanentLoss: stImpermanentLoss,
            jtCoverageImpermanentLoss: jtCoverageImpermanentLoss,
            jtSelfImpermanentLoss: jtSelfImpermanentLoss,
            // No fees are ever taken if NAVs were conserved
            stProtocolFeeAccrued: ZERO_NAV_UNITS,
            jtProtocolFeeAccrued: ZERO_NAV_UNITS,
            // Additional data about the market's post-sync state
            utilizationWAD: UtilsLib.computeUtilization(_stPostOpRawNAV, _jtPostOpRawNAV, $.betaWAD, $.coverageWAD, jtEffectiveNAV),
            ltvWAD: UtilsLib.computeLTV(stEffectiveNAV, stImpermanentLoss, jtEffectiveNAV),
            fixedTermEndTimestamp: $.fixedTermEndTimestamp
        });

        emit TrancheAccountingSynced(state);
    }

    /// @inheritdoc IRoycoAccountant
    function postOpSyncTrancheAccountingAndEnforceCoverage(
        Operation _op,
        NAV_UNIT _stPostOpRawNAV,
        NAV_UNIT _jtPostOpRawNAV,
        NAV_UNIT _stDepositPreOpNAV,
        NAV_UNIT _jtDepositPreOpNAV,
        NAV_UNIT _stRedeemPreOpNAV,
        NAV_UNIT _jtRedeemPreOpNAV
    )
        external
        override(IRoycoAccountant)
        returns (SyncedAccountingState memory state)
    {
        // Execute a post-op NAV synchronization
        state = postOpSyncTrancheAccounting(_op, _stPostOpRawNAV, _jtPostOpRawNAV, _stDepositPreOpNAV, _jtDepositPreOpNAV, _stRedeemPreOpNAV, _jtRedeemPreOpNAV);
        // Enforce the market's coverage requirement
        require(_isCoverageRequirementSatisfied(state.utilizationWAD), COVERAGE_REQUIREMENT_UNSATISFIED());
    }

    /**
     * @inheritdoc IRoycoAccountant
     * @dev Junior capital must be sufficient to absorb losses to the senior exposure up to the coverage ratio
     * @dev Informally: junior loss absorbtion buffer >= total covered exposure
     * @dev Formally: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * β)) * COV
     *      JT_EFFECTIVE_NAV is JT's current loss absorbtion buffer after applying all prior JT yield accrual and coverage adjustments
     *      ST_RAW_NAV and JT_RAW_NAV are the mark-to-market NAVs of the tranches
     *      β is the JT's sensitivity to the same downside stress that affects ST (eg. 0 if JT is in RFR and 1 if JT and ST are in the same opportunity)
     * @dev If we rearrange the coverage requirement, we get:
     *      1 >= ((ST_RAW_NAV + (JT_RAW_NAV * β)) * COV) / JT_EFFECTIVE_NAV
     *      Notice that the RHS is identical to how we define utilization
     *      Hence, the coverage requirement can be written as 1 >= Utilization, or equivalently, Utilization <= 1
     */
    function isCoverageRequirementSatisfied() public view override(IRoycoAccountant) returns (bool) {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        // Compute the utilization and return whether or not the senior tranche is properly collateralized based on persisted NAVs
        uint256 utilization = UtilsLib.computeUtilization($.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV);
        return _isCoverageRequirementSatisfied(utilization);
    }

    /**
     * @notice Returns whether the coverage requirement is satisfied given the utilization
     * @param _utilizationWAD The utilization of the market, scaled to WAD precision
     * @return satisfied A boolean indicating whether the coverage requirement is satisfied
     */
    function _isCoverageRequirementSatisfied(uint256 _utilizationWAD) internal pure returns (bool) {
        return (_utilizationWAD <= WAD);
    }

    /**
     * @inheritdoc IRoycoAccountant
     * @dev Coverage Invariant: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * β)) * COV
     * @dev Max assets depositable into ST, x: JT_EFFECTIVE_NAV = ((ST_RAW_NAV + x) + (JT_RAW_NAV * β)) * COV
     *      Isolate x: x = (JT_EFFECTIVE_NAV / COV) - (JT_RAW_NAV * β) - ST_RAW_NAV
     */
    function maxSTDepositGivenCoverage(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) external view override(IRoycoAccountant) returns (NAV_UNIT maxSTDeposit) {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        // Preview a NAV sync to get the market's current state
        (SyncedAccountingState memory state,,,) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _previewJTYieldShareAccrual());
        // Solve for x, rounding in favor of senior protection
        // Compute the total covered assets by the junior tranche loss absorption buffer
        NAV_UNIT totalCoveredAssets = state.jtEffectiveNAV.mulDiv(WAD, $.coverageWAD, Math.Rounding.Floor);
        // Compute the assets required to cover current junior tranche exposure
        // Also account for JT's dust tolerance to preclude reverts due to rounding after ST deposit (if both are exposed to the same underlying rounding)
        NAV_UNIT jtCoverageRequired = _jtRawNAV.mulDiv($.betaWAD, WAD, Math.Rounding.Ceil) + $.jtNAVDustTolerance;
        // Compute the amount of assets that can be deposited into senior while retaining full coverage
        // Also account for ST's dust tolerance to preclude reverts due to rounding after ST deposit
        maxSTDeposit = totalCoveredAssets.saturatingSub(jtCoverageRequired).saturatingSub(_stRawNAV).saturatingSub($.stNAVDustTolerance);
    }

    /**
     * @inheritdoc IRoycoAccountant
     * @dev Coverage Invariant: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * β)) * COV
     * @dev When assets are claimed from the JT, they are always liquidated in the same proportion as the tranche's total claims on the ST and JT assets
     * @dev Let S be the JT's total claims on ST assets and J be the JT's total claims on JT assets, in NAV Units. The total claims on the ST and JT assets are S + J NAV Units
     * @dev Let K_S be S / (S + J) and K_J be J / (S + J)
     * @dev Therefore, if a total NAV of y is claimed from the JT, K_S * y will be claimed from the ST_RAW_NAV and K_J * y will be claimed from the JT_RAW_NAV
     * @dev Max assets withdrawable from JT, y: (JT_EFFECTIVE_NAV - y) = ((ST_RAW_NAV - K_S * y) + ((JT_RAW_NAV - K_J * y) * β)) * COV
     *      Isolate y: y = (JT_EFFECTIVE_NAV - (COV * (ST_RAW_NAV + (JT_RAW_NAV * β)))) / (1 - (COV * (K_S + β * K_J)))
     */
    function maxJTWithdrawalGivenCoverage(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _jtClaimOnStUnits,
        NAV_UNIT _jtClaimOnJtUnits
    )
        external
        view
        override(IRoycoAccountant)
        returns (NAV_UNIT totalNAVClaimable, NAV_UNIT stClaimable, NAV_UNIT jtClaimable)
    {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        // Get the surplus JT assets in NAV units
        NAV_UNIT surplusJTAssets = _calculateSurplusJtAssetsInNav(_stRawNAV, _jtRawNAV);

        // Compute the total JT claim on NAV and preemptively return if zero
        NAV_UNIT totalJTClaims = _jtClaimOnStUnits + _jtClaimOnJtUnits;
        if (totalJTClaims == ZERO_NAV_UNITS) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        // Calculate K_S
        uint256 kS_WAD = toUint256(_jtClaimOnStUnits.mulDiv(WAD, totalJTClaims, Math.Rounding.Floor));
        // Calculate K_J
        uint256 kJ_WAD = toUint256(_jtClaimOnJtUnits.mulDiv(WAD, totalJTClaims, Math.Rounding.Floor));
        // Compute how much coverage the system retains per 1 nav unit of JT assets withdrawn scaled to WAD precision
        uint256 coverageRetentionWAD =
            (WAD - uint256($.coverageWAD).mulDiv(kS_WAD + uint256($.betaWAD).mulDiv(kJ_WAD, WAD, Math.Rounding.Floor), WAD, Math.Rounding.Floor));
        // Calculate how much of the surplus can be withdrawn while satisfying the coverage requirement
        totalNAVClaimable = surplusJTAssets.mulDiv(WAD, coverageRetentionWAD, Math.Rounding.Floor);
        if (totalNAVClaimable == ZERO_NAV_UNITS) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        // Split it into individual tranche's claims
        stClaimable = totalNAVClaimable.mulDiv(kS_WAD, WAD, Math.Rounding.Floor);
        jtClaimable = totalNAVClaimable.mulDiv(kJ_WAD, WAD, Math.Rounding.Floor);
        // Account for the market's dust tolerance to preclude reverts due to rounding after JT withdrawal
        // Apply both dust tolerances since JT withdrawals can include yield and IL repayments from ST in addition to its own NAV
        stClaimable = stClaimable.saturatingSub($.stNAVDustTolerance);
        jtClaimable = jtClaimable.saturatingSub($.jtNAVDustTolerance);
    }

    /**
     * @notice Calculates the surplus JT assets in NAV units
     * @param _stRawNAV The senior tranche's current raw NAV in the market's NAV units
     * @param _jtRawNAV The junior tranche's current raw NAV in the market's NAV units
     * @return surplusJTAssets The surplus JT assets in NAV units
     */
    function _calculateSurplusJtAssetsInNav(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) internal view returns (NAV_UNIT surplusJTAssets) {
        // Get the storage pointer to the accountant state and cache beta and coverage
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        uint256 betaWAD = $.betaWAD;
        // Preview a NAV sync to get the market's current state
        (SyncedAccountingState memory state,,,) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _previewJTYieldShareAccrual());
        // Compute the total covered exposure of the underlying investment, rounding in favor of senior protection
        NAV_UNIT totalCoveredExposure = _stRawNAV + _jtRawNAV.mulDiv(betaWAD, WAD, Math.Rounding.Ceil);
        // Compute the minimum junior tranche assets required to cover the exposure as per the market's coverage requirement
        NAV_UNIT requiredJTAssets = totalCoveredExposure.mulDiv($.coverageWAD, WAD, Math.Rounding.Ceil);
        // Compute the surplus coverage currently provided by the junior tranche based on its currently remaining loss-absorption buffer
        surplusJTAssets = state.jtEffectiveNAV.saturatingSub(requiredJTAssets);
    }

    /**
     * @notice Synchronizes all tranche NAVs and impermanent losses based on unrealized PNLs of the underlying investment(s)
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _twJTYieldShareAccruedWAD The currently accrued time-weighted JT yield share YDM output since the last distribution, scaled to WAD precision
     * @return state A struct containing all mark to market NAV, impermanent losses, and fee data after executing the sync
     * @return initialMarketState The initial state the market was in before the synchronization
     * @return yieldDistributed A boolean indicating whether ST yield was split between ST and JT
     * @return jtCoverageImpermanentLossErased The amount of JT coverage loss erased (reset to 0)
     */
    function _previewSyncTrancheAccounting(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint192 _twJTYieldShareAccruedWAD
    )
        internal
        view
        returns (SyncedAccountingState memory state, MarketState initialMarketState, bool yieldDistributed, NAV_UNIT jtCoverageImpermanentLossErased)
    {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Cache the last checkpointed market state, effective NAV, and impermanent losses for each tranche
        NAV_UNIT stEffectiveNAV = $.lastSTEffectiveNAV;
        NAV_UNIT jtEffectiveNAV = $.lastJTEffectiveNAV;
        NAV_UNIT stImpermanentLoss = $.lastSTImpermanentLoss;
        NAV_UNIT jtCoverageImpermanentLoss = $.lastJTCoverageImpermanentLoss;
        NAV_UNIT jtSelfImpermanentLoss = $.lastJTSelfImpermanentLoss;
        NAV_UNIT stProtocolFeeAccrued;
        NAV_UNIT jtProtocolFeeAccrued;

        // Compute the deltas in the raw NAVs of each tranche
        // The deltas represent the unrealized PNL of the underlying investment since the last NAV checkpoints
        int256 deltaST = UnitsMathLib.computeNAVDelta(_stRawNAV, $.lastSTRawNAV);
        int256 deltaJT = UnitsMathLib.computeNAVDelta(_jtRawNAV, $.lastJTRawNAV);

        // The net JT gains after ST IL recovery and JT self inflicted IL is recovered. The protocol fee accrued is calculated on this amount.
        NAV_UNIT jtNetGain = ZERO_NAV_UNITS;

        // Mark both the tranche NAVs to market
        /// @dev STEP_APPLY_JT_LOSS: The JT assets depreciated in value
        if (deltaJT < 0) {
            /// @dev STEP_JT_ABSORB_LOSS: JT's remaning loss-absorption buffer incurs as much of the loss as possible
            NAV_UNIT jtLoss = toNAVUnits(-deltaJT);
            NAV_UNIT jtAbsorbableLoss = UnitsMathLib.min(jtLoss, jtEffectiveNAV);
            if (jtAbsorbableLoss != ZERO_NAV_UNITS) {
                // Incur the maximum absorbable losses to remaining JT loss capital
                jtEffectiveNAV = (jtEffectiveNAV - jtAbsorbableLoss);
                // This is booked as JT self inflicted impermanent loss
                jtSelfImpermanentLoss = (jtSelfImpermanentLoss + jtAbsorbableLoss);
                jtLoss = (jtLoss - jtAbsorbableLoss);
            }
            /// @dev STEP_ST_INCURS_RESIDUAL_LOSSES: Residual loss after emptying JT's remaning loss-absorption buffer are incurred by ST
            if (jtLoss != ZERO_NAV_UNITS) {
                // The excess loss is absorbed by ST
                stEffectiveNAV = (stEffectiveNAV - jtLoss);
                // This is booked as ST impermanent loss
                stImpermanentLoss = (stImpermanentLoss + jtLoss);
            }
            /// @dev STEP_APPLY_JT_GAIN: The JT assets appreciated in value
        } else if (deltaJT > 0) {
            NAV_UNIT jtGain = toNAVUnits(deltaJT);
            /// @dev STEP_ST_IMPERMANENT_LOSS_RECOVERY: First, recover any ST impermanent losses (first claim on JT appreciation)
            NAV_UNIT stImpermanentLossRecovery = UnitsMathLib.min(jtGain, stImpermanentLoss);
            if (stImpermanentLossRecovery != ZERO_NAV_UNITS) {
                // Recover as much of the ST impermanent loss as possible
                stImpermanentLoss = (stImpermanentLoss - stImpermanentLossRecovery);
                // Apply the retroactive coverage to the ST
                stEffectiveNAV = (stEffectiveNAV + stImpermanentLossRecovery);
                jtGain = (jtGain - stImpermanentLossRecovery);
            }
            /// @dev STEP_JT_SELF_IMPERMANENT_LOSS_RECOVERY: Second, recover any JT self inflicted impermanent losses (second claim on JT appreciation)
            NAV_UNIT jtSelfImpermanentLossRecovery = UnitsMathLib.min(jtGain, jtSelfImpermanentLoss);
            if (jtSelfImpermanentLossRecovery != ZERO_NAV_UNITS) {
                // Recover as much of the JT self impermanent loss as possible
                jtSelfImpermanentLoss = (jtSelfImpermanentLoss - jtSelfImpermanentLossRecovery);
                // Apply the JT self IL recovery
                jtEffectiveNAV = (jtEffectiveNAV + jtSelfImpermanentLossRecovery);
                jtGain = (jtGain - jtSelfImpermanentLossRecovery);
            }
            /// @dev STEP_JT_ACCRUES_RESIDUAL_GAINS: JT accrues any remaining appreciation after clearing ST IL and JT self inflicted IL
            if (jtGain != ZERO_NAV_UNITS) {
                jtNetGain = jtGain;
                // Compute the protocol fee taken on this JT yield accrual if it is not attributable to any rounding/dust
                if (jtNetGain > $.jtNAVDustTolerance) jtProtocolFeeAccrued = jtNetGain.mulDiv($.jtProtocolFeeWAD, WAD, Math.Rounding.Floor);
                // Book the residual gains to the JT
                jtEffectiveNAV = (jtEffectiveNAV + jtNetGain);
            }
        }

        /// @dev STEP_APPLY_ST_LOSS: The ST assets depreciated in value
        if (deltaST < 0) {
            NAV_UNIT stLoss = toNAVUnits(-deltaST);
            /// @dev STEP_APPLY_JT_COVERAGE_TO_ST: Apply any possible coverage to ST provided by JT's loss-absorption buffer
            NAV_UNIT coverageApplied = UnitsMathLib.min(stLoss, jtEffectiveNAV);
            if (coverageApplied != ZERO_NAV_UNITS) {
                // If there was a net JT gain, reduce it by the amount of coverage applied and recalculate the protocol fee accrued on the true net gains
                if (jtNetGain != ZERO_NAV_UNITS) {
                    jtNetGain = jtNetGain.saturatingSub(coverageApplied);
                    jtProtocolFeeAccrued = jtNetGain.mulDiv($.jtProtocolFeeWAD, WAD, Math.Rounding.Floor);
                }
                // Apply the coverage to JT effective NAV
                jtEffectiveNAV = (jtEffectiveNAV - coverageApplied);
                // Any coverage provided is a ST liability to JT
                jtCoverageImpermanentLoss = (jtCoverageImpermanentLoss + coverageApplied);
            }
            /// @dev STEP_ST_INCURS_RESIDUAL_LOSSES: Apply any uncovered losses by JT to ST
            NAV_UNIT netStLoss = stLoss - coverageApplied;
            if (netStLoss != ZERO_NAV_UNITS) {
                // Apply residual losses to ST
                stEffectiveNAV = (stEffectiveNAV - netStLoss);
                // The uncovered portion of the ST loss is a JT liability to ST
                stImpermanentLoss = (stImpermanentLoss + netStLoss);
            }
            /// @dev STEP_APPLY_ST_GAIN: The ST assets appreciated in value
        } else if (deltaST > 0) {
            NAV_UNIT stGain = toNAVUnits(deltaST);
            /// @dev STEP_ST_IMPERMANENT_LOSS_RECOVERY: First, recover any ST impermanent losses (first claim on ST appreciation)
            NAV_UNIT impermanentLossRecovery = UnitsMathLib.min(stGain, stImpermanentLoss);
            if (impermanentLossRecovery != ZERO_NAV_UNITS) {
                // Recover as much of the ST impermanent loss as possible
                stImpermanentLoss = (stImpermanentLoss - impermanentLossRecovery);
                // Apply the ST IL recovery
                stEffectiveNAV = (stEffectiveNAV + impermanentLossRecovery);
                stGain = (stGain - impermanentLossRecovery);
            }
            /// @dev STEP_JT_COVERAGE_IMPERMANENT_LOSS_RECOVERY: Second, recover any JT coverage inflicted impermanent losses (second claim on ST appreciation)
            impermanentLossRecovery = UnitsMathLib.min(stGain, jtCoverageImpermanentLoss);
            if (impermanentLossRecovery != ZERO_NAV_UNITS) {
                // Recover as much of the JT coverage impermanent loss as possible
                jtCoverageImpermanentLoss = (jtCoverageImpermanentLoss - impermanentLossRecovery);
                // Apply the JT coverage IL recovery
                jtEffectiveNAV = (jtEffectiveNAV + impermanentLossRecovery);
                stGain = (stGain - impermanentLossRecovery);
            }
            /// @dev STEP_DISTRIBUTE_YIELD: There are no remaining impermanent losses that ST yield is obligated to repay, the residual gains will be used to distribute yield to both tranches
            if (stGain != ZERO_NAV_UNITS) {
                // Mark yield as distributed if the gain is not attributable to any rounding/dust
                if (stGain > $.stNAVDustTolerance) yieldDistributed = true;
                // Compute the time weighted average JT share of yield
                uint256 elapsed = block.timestamp - $.lastDistributionTimestamp;
                // If the last yield distribution happened in the same block, use the instantaneous JT yield share. Else, use the time-weighted average JT yield share since the last distribution
                NAV_UNIT jtGain;
                if (elapsed == 0) {
                    // Get the instantaneous YDM output and ensure that JT cannot earn more than 100% of senior appreciation
                    uint256 instantaneousJtYieldShareWAD =
                        IYDM($.ydm).previewJTYieldShare($.lastMarketState, $.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV);
                    if (instantaneousJtYieldShareWAD > WAD) instantaneousJtYieldShareWAD = WAD;
                    jtGain = stGain.mulDiv(instantaneousJtYieldShareWAD, WAD, Math.Rounding.Floor);
                } else {
                    jtGain = stGain.mulDiv(_twJTYieldShareAccruedWAD, elapsed * WAD, Math.Rounding.Floor);
                }
                // Apply the yield split to JT's effective NAV
                if (jtGain != ZERO_NAV_UNITS) {
                    // Compute the protocol fee taken on this JT yield accrual if it is not attributable to any rounding/dust
                    if (yieldDistributed) jtProtocolFeeAccrued = (jtProtocolFeeAccrued + jtGain.mulDiv($.jtProtocolFeeWAD, WAD, Math.Rounding.Floor));
                    jtEffectiveNAV = (jtEffectiveNAV + jtGain);
                    stGain = (stGain - jtGain);
                }
                // Compute the protocol fee taken on this ST yield accrual if it is not attributable to any rounding/dust
                if (yieldDistributed) stProtocolFeeAccrued = stGain.mulDiv($.stProtocolFeeWAD, WAD, Math.Rounding.Floor);
                // Book the residual gain to the ST
                stEffectiveNAV = (stEffectiveNAV + stGain);
            }
        }

        // Enforce the NAV conservation invariant
        require((_stRawNAV + _jtRawNAV) == (stEffectiveNAV + jtEffectiveNAV), NAV_CONSERVATION_VIOLATION());

        // Determine the resulting market state:
        // 1. Forced Perpetual: The fixed term duration is set to 0 (permanently perpetual), current fixed term elapsed, or LLTV has been breached (undercollateralized) or ST IL exists (distressed)
        // 2. Normal Perpetual: JT coverage IL is within dust tolerance (staying perpetual) or fully recovered (exiting fixed term for perpetual)
        // 3. Fixed term: The JT coverage IL is above the dust tolerance of the market, fixed term duration hasn't elapsed, LLTV hasn't been breached, and ST IL nonexistant
        initialMarketState = $.lastMarketState;
        MarketState resultingMarketState;
        uint32 fixedTermEndTimestamp = $.fixedTermEndTimestamp;
        uint24 fixedTermDurationSeconds = $.fixedTermDurationSeconds;
        uint256 ltvWAD = UtilsLib.computeLTV(stEffectiveNAV, stImpermanentLoss, jtEffectiveNAV);
        // If the market is permanently perpetual, the fixed term elapsed, undercollateralized, or distressed, the market must be in a a perpetual state
        if (
            fixedTermDurationSeconds == 0 || (initialMarketState == MarketState.FIXED_TERM && fixedTermEndTimestamp <= block.timestamp) || ltvWAD >= $.lltvWAD
                || stImpermanentLoss != ZERO_NAV_UNITS
        ) {
            resultingMarketState = MarketState.PERPETUAL;
            // JT coverage impermanent loss has to be explicitly cleared in this branch:
            // If the fixed term duration is 0, the market is permanently in a perpetual state and never incurs any JT coverage IL
            // If the current fixed term has elapsed, the market needs to transition to a perpetual state since the transient JT protection period is complete
            // If LLTV has been breached without existant ST IL, the market is approaching an uncollateralized state: ST needs to be able to withdraw to avoid losses and the YDM needs to kick in to reinstate proper collateralization
            // If ST IL exists, the market is in a distressed state: STs need to be able to book losses and any future appreciation will go to making ST whole again
            jtCoverageImpermanentLossErased = jtCoverageImpermanentLoss;
            jtCoverageImpermanentLoss = ZERO_NAV_UNITS;
            // Reset the fixed term end timestamp
            fixedTermEndTimestamp = 0;
            // If the market has less than dust coverage provided by JT
        } else if (jtCoverageImpermanentLoss <= $.stNAVDustTolerance) {
            // JT coverage IL is either non-existant or can be attributed to dust ST losses (eg. rounding in the underlying ST NAV)
            // If market was in a perpetual state or the coverage IL was completely wiped, transition to a perpetual state
            if (initialMarketState == MarketState.PERPETUAL || jtCoverageImpermanentLoss == ZERO_NAV_UNITS) {
                resultingMarketState = MarketState.PERPETUAL;
                // Reset the fixed term end timestamp
                fixedTermEndTimestamp = 0;
                // If market was in a fixed term state, remain in it until dust tolerance is completely restored
            } else {
                // This ensures that we always have a buffer of at least the dust tolerance when entering a fresh perpetual state
                resultingMarketState = MarketState.FIXED_TERM;
                // Fees are not taken in a fixed term state
                stProtocolFeeAccrued = ZERO_NAV_UNITS; // Formality: Should naturally never be non-zero in a fixed term state
                jtProtocolFeeAccrued = ZERO_NAV_UNITS;
            }
        } else {
            resultingMarketState = MarketState.FIXED_TERM;
            // Fees are not taken in a fixed term state
            stProtocolFeeAccrued = ZERO_NAV_UNITS; // Formality: Should naturally never be non-zero in a fixed term state
            jtProtocolFeeAccrued = ZERO_NAV_UNITS;
            // If the market was in a perpetual state, update the fixed term end timestamp
            if (initialMarketState == MarketState.PERPETUAL) {
                fixedTermEndTimestamp = uint32(block.timestamp + fixedTermDurationSeconds);
            }
        }

        // Marshal the post-sync state and return to the caller
        state = SyncedAccountingState({
            marketState: resultingMarketState,
            stRawNAV: _stRawNAV,
            jtRawNAV: _jtRawNAV,
            stEffectiveNAV: stEffectiveNAV,
            jtEffectiveNAV: jtEffectiveNAV,
            stImpermanentLoss: stImpermanentLoss,
            jtCoverageImpermanentLoss: jtCoverageImpermanentLoss,
            jtSelfImpermanentLoss: jtSelfImpermanentLoss,
            stProtocolFeeAccrued: stProtocolFeeAccrued,
            jtProtocolFeeAccrued: jtProtocolFeeAccrued,
            // Additional data about the market's post-sync state
            utilizationWAD: UtilsLib.computeUtilization(_stRawNAV, _jtRawNAV, $.betaWAD, $.coverageWAD, jtEffectiveNAV),
            ltvWAD: ltvWAD,
            fixedTermEndTimestamp: fixedTermEndTimestamp
        });
    }

    /**
     * @notice Accrues the JT yield share since the last yield distribution
     * @dev Gets the instantaneous JT yield share and accumulates it over the time elapsed since the last accrual
     * @return twJTYieldShareAccruedWAD The updated time-weighted JT yield share since the last yield distribution
     */
    function _accrueJTYieldShare() internal returns (uint192 twJTYieldShareAccruedWAD) {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $.lastAccrualTimestamp;
        if (lastUpdate == 0) {
            // Initialize the checkpoint timestamps if this is the first accrual
            $.lastAccrualTimestamp = uint32(block.timestamp);
            $.lastDistributionTimestamp = uint32(block.timestamp);
            return 0;
        }

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return $.twJTYieldShareAccruedWAD;

        // Get the instantaneous JT yield share, scaled to WAD precision
        uint256 jtYieldShareWAD = IYDM($.ydm).jtYieldShare($.lastMarketState, $.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV);
        // Ensure that JT cannot earn more than 100% of senior appreciation
        if (jtYieldShareWAD > WAD) jtYieldShareWAD = WAD;

        // Accrue the time-weighted yield share accrued to JT since the last tranche interaction
        /// forge-lint: disable-next-item(unsafe-typecast)
        twJTYieldShareAccruedWAD = $.twJTYieldShareAccruedWAD += uint192(jtYieldShareWAD * elapsed);
        $.lastAccrualTimestamp = uint32(block.timestamp);

        emit JuniorTrancheYieldShareAccrued(jtYieldShareWAD, twJTYieldShareAccruedWAD, uint32(block.timestamp));
    }

    /**
     * @notice Computes and returns the currently accrued JT yield share since the last yield distribution
     * @dev Gets the instantaneous JT yield share and accumulates it over the time elapsed since the last accrual
     * @return The updated time-weighted JT yield share since the last yield distribution
     */
    function _previewJTYieldShareAccrual() internal view returns (uint192) {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $.lastAccrualTimestamp;
        if (lastUpdate == 0) return 0;

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return $.twJTYieldShareAccruedWAD;

        // Get the instantaneous JT yield share, scaled to WAD precision
        uint256 jtYieldShareWAD =
            IYDM($.ydm).previewJTYieldShare($.lastMarketState, $.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV);
        // Ensure that JT cannot earn more than 100% of senior appreciation
        if (jtYieldShareWAD > WAD) jtYieldShareWAD = WAD;

        // Apply the accural of JT yield share to the accumulator, weighted by the time elapsed
        /// forge-lint: disable-next-item(unsafe-typecast)
        return ($.twJTYieldShareAccruedWAD + uint192(jtYieldShareWAD * elapsed));
    }

    /// @inheritdoc IRoycoAccountant
    function setYDM(address _ydm, bytes calldata _ydmInitializationData) external override(IRoycoAccountant) restricted withSyncedAccounting {
        // Initialize and set the new YDM for this market
        _initializeYDM(_ydm, _ydmInitializationData);
        _getRoycoAccountantStorage().ydm = _ydm;
        emit YDMUpdated(_ydm);
    }

    /// @inheritdoc IRoycoAccountant
    function setSeniorTrancheProtocolFee(uint64 _stProtocolFeeWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        // Ensure that the protocol fee percentage is valid
        require(_stProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        _getRoycoAccountantStorage().stProtocolFeeWAD = _stProtocolFeeWAD;
        emit SeniorTrancheProtocolFeeUpdated(_stProtocolFeeWAD);
    }

    /// @inheritdoc IRoycoAccountant
    function setJuniorTrancheProtocolFee(uint64 _jtProtocolFeeWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        // Ensure that the protocol fee percentage is valid
        require(_jtProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        _getRoycoAccountantStorage().jtProtocolFeeWAD = _jtProtocolFeeWAD;
        emit JuniorTrancheProtocolFeeUpdated(_jtProtocolFeeWAD);
    }

    /// @inheritdoc IRoycoAccountant
    function setCoverage(uint64 _coverageWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        // Validate the new coverage configuration
        _validateCoverageConfig(_coverageWAD, $.betaWAD, $.lltvWAD);
        $.coverageWAD = _coverageWAD;
        emit CoverageUpdated(_coverageWAD);
    }

    /// @inheritdoc IRoycoAccountant
    function setBeta(uint96 _betaWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        // Validate the new coverage configuration
        _validateCoverageConfig($.coverageWAD, _betaWAD, $.lltvWAD);
        $.betaWAD = _betaWAD;
        emit BetaUpdated(_betaWAD);
    }

    /// @inheritdoc IRoycoAccountant
    function setLLTV(uint64 _lltvWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        // Validate the new coverage configuration
        _validateCoverageConfig($.coverageWAD, $.betaWAD, _lltvWAD);
        $.lltvWAD = _lltvWAD;
        emit LLTVUpdated(_lltvWAD);
    }

    /// @inheritdoc IRoycoAccountant
    function setCoverageConfiguration(
        uint64 _coverageWAD,
        uint96 _betaWAD,
        uint64 _lltvWAD
    )
        external
        override(IRoycoAccountant)
        restricted
        withSyncedAccounting
    {
        // Validate the new coverage configuration
        _validateCoverageConfig(_coverageWAD, _betaWAD, _lltvWAD);
        // Set the new config
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        $.coverageWAD = _coverageWAD;
        emit CoverageUpdated(_coverageWAD);
        $.betaWAD = _betaWAD;
        emit BetaUpdated(_betaWAD);
        $.lltvWAD = _lltvWAD;
        emit LLTVUpdated(_lltvWAD);
    }

    /// @inheritdoc IRoycoAccountant
    function setFixedTermDuration(uint24 _fixedTermDurationSeconds) external override(IRoycoAccountant) restricted withSyncedAccounting {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        $.fixedTermDurationSeconds = _fixedTermDurationSeconds;
        // If the specified duration is 0, the market will permanently be in a perpetual state
        if (_fixedTermDurationSeconds == 0) {
            emit JTCoverageImpermanentLossErased($.lastJTCoverageImpermanentLoss);
            $.lastJTCoverageImpermanentLoss = ZERO_NAV_UNITS;
            $.lastMarketState = MarketState.PERPETUAL;
        }
        emit FixedTermDurationUpdated(_fixedTermDurationSeconds);
    }

    /// @inheritdoc IRoycoAccountant
    function setSeniorTrancheDustTolerance(NAV_UNIT _stNAVDustTolerance) external override(IRoycoAccountant) restricted withSyncedAccounting {
        _getRoycoAccountantStorage().stNAVDustTolerance = _stNAVDustTolerance;
        emit SeniorTrancheDustToleranceUpdated(_stNAVDustTolerance);
    }

    /// @inheritdoc IRoycoAccountant
    function setJuniorTrancheDustTolerance(NAV_UNIT _jtNAVDustTolerance) external override(IRoycoAccountant) restricted withSyncedAccounting {
        _getRoycoAccountantStorage().jtNAVDustTolerance = _jtNAVDustTolerance;
        emit JuniorTrancheDustToleranceUpdated(_jtNAVDustTolerance);
    }

    /// @inheritdoc IRoycoAccountant
    function getState() external view override(IRoycoAccountant) returns (RoycoAccountantState memory) {
        return _getRoycoAccountantStorage();
    }

    /// @inheritdoc IRoycoAccountant
    function getLiquidationParams() external view override(IRoycoAccountant) returns (uint64 lltvWAD, uint96 betaWAD) {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        return ($.lltvWAD, $.betaWAD);
    }

    /**
     * @notice Validates the coverage requirement parameters of the market
     * @param _coverageWAD The coverage ratio that the senior tranche is expected to be protected by, scaled to WAD precision
     * @param _betaWAD The JT's sensitivity to the same downside stress that affects ST, scaled to WAD precision
     * @param _lltvWAD The liquidation loan to value (LLTV) for this market, scaled to WAD precision
     */
    function _validateCoverageConfig(uint64 _coverageWAD, uint96 _betaWAD, uint64 _lltvWAD) internal pure {
        // Ensure that the coverage requirement is valid
        require((_coverageWAD >= MIN_COVERAGE_WAD) && (_coverageWAD < WAD), INVALID_COVERAGE_CONFIG());
        // Ensure that JT withdrawals are not permanently bricked
        require(uint256(_coverageWAD).mulDiv(_betaWAD, WAD, Math.Rounding.Ceil) < WAD, INVALID_COVERAGE_CONFIG());
        /**
         * Ensure that the LLTV is set correctly (between the max allowed initial LTV and 100%)
         * Maximum Initial LTV Derivation:
         * Given:
         *   LTV = (ST_EFFECTIVE_NAV + ST_IL) / (ST_EFFECTIVE_NAV + JT_EFFECTIVE_NAV)
         *   Initial Utilization = ((ST_EFFECTIVE_NAV + JT_RAW_NAV * β) * COV) / JT_EFFECTIVE_NAV
         *   Note: Initially, JT_RAW_NAV == JT_EFFECTIVE_NAV and ST_IL == 0 since no losses have been incurred by ST
         *   Initial Utilization = ((ST_EFFECTIVE_NAV + JT_EFFECTIVE_NAV * β) * COV) / JT_EFFECTIVE_NAV
         *
         * At Utilization = 1 (boundary of proper collateralization), solving for JT_EFFECTIVE_NAV:
         *   1 = ((ST_EFFECTIVE_NAV + JT_EFFECTIVE_NAV * β) * COV) / JT_EFFECTIVE_NAV
         *   JT_EFFECTIVE_NAV = (ST_EFFECTIVE_NAV + JT_EFFECTIVE_NAV * β) * COV
         *   JT_EFFECTIVE_NAV = ST_EFFECTIVE_NAV * COV + JT_EFFECTIVE_NAV * β * COV
         *   JT_EFFECTIVE_NAV - JT_EFFECTIVE_NAV * β * COV = ST_EFFECTIVE_NAV * COV
         *   JT_EFFECTIVE_NAV * (1 - β * COV) = ST_EFFECTIVE_NAV * COV
         *   JT_EFFECTIVE_NAV = ST_EFFECTIVE_NAV * COV / (1 - β * COV)
         *
         * Substituting JT_EFFECTIVE_NAV into LTV:
         *   LTV = ST_EFFECTIVE_NAV / (ST_EFFECTIVE_NAV + ST_EFFECTIVE_NAV * COV / (1 - β * COV))
         *       = 1 / (1 + COV / (1 - β * COV))
         *       = (1 - β * COV) / (1 - β * COV + COV)
         *       = (1 - β * COV) / (1 + COV - β * COV)
         *       = (1 - β * COV) / (1 + COV * (1 - β))
         *
         * This represents the maximum initial LTV when the market is exactly at Utilization = 1
         * LLTV must be strictly greater than this value to ensure it can only be breached after JT capital has started absorbing ST losses
         */
        // Round in favor of keeping max initial LTV high (conservative for setting LLTV)
        uint256 betaCov = uint256(_coverageWAD).mulDiv(_betaWAD, WAD, Math.Rounding.Floor);
        uint256 numerator = WAD - betaCov;
        uint256 denominator = WAD + _coverageWAD - betaCov;
        uint256 maxLTV = numerator.mulDiv(WAD, denominator, Math.Rounding.Ceil);
        // LLTV must be between the max allowed initial LTV and 100% LTV
        require(maxLTV < _lltvWAD && _lltvWAD < WAD, INVALID_LLTV());
    }

    /**
     * @notice Initializes the YDM (Yield Distribution Model) if required for this market
     * @param _ydm The new YDM address to set
     * @param _ydmInitializationData The data used to initialize the new YDM for this market
     */
    function _initializeYDM(address _ydm, bytes calldata _ydmInitializationData) internal {
        // Ensure that the YDM is not null
        require(_ydm != address(0), NULL_YDM_ADDRESS());
        // Initialize the YDM if required
        if (_ydmInitializationData.length != 0) {
            (bool success, bytes memory data) = _ydm.call(_ydmInitializationData);
            require(success, FAILED_TO_INITIALIZE_YDM(data));
        }
    }

    /**
     * @notice Returns a storage pointer to the RoycoAccountantState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the accountant's state
     */
    function _getRoycoAccountantStorage() internal pure returns (RoycoAccountantState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_ACCOUNTANT_STORAGE_SLOT
        }
    }
}
