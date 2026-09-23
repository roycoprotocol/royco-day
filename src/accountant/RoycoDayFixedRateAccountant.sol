// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { IYDM } from "../interfaces/IYDM.sol";
import { IRoycoDayAccountant } from "../interfaces/accountant/IRoycoDayAccountant.sol";
import { IRoycoDayFixedRateAccountant } from "../interfaces/accountant/IRoycoDayFixedRateAccountant.sol";
import { WAD, ZERO_NAV_UNITS } from "../libraries/Constants.sol";
import { MarketState, NAV_UNIT, SyncedAccountingState } from "../libraries/Types.sol";
import { Math, RoycoUnitsMath } from "../libraries/Units.sol";
import { DispatchLogic } from "../libraries/logic/DispatchLogic.sol";
import { UtilizationLogic } from "../libraries/logic/UtilizationLogic.sol";
import { RoycoDayAccountant } from "./base/RoycoDayAccountant.sol";

/**
 * @title RoycoDayFixedRateAccountant
 * @author Shivaansh Kapoor, Ankur Dubey, Tomer Ganor
 * @notice Performs and tracks the accounting, coverage, and liquidity operations and requirements for a Royco market
 * @notice Responsible for marking tranche NAVs to market, accruing the senior tranche's fixed rate coupon, tracking the JT impermanent loss, distributing the excess yield via the LPT YDM, and computing protocol fees
 * @dev The senior tranche earns a fixed rate coupon underwritten by the junior tranche: the coupon is the fixed rate applied to the senior tranche's committed effective NAV over the window since the last settlement, settled only by a sync that observes a collateral NAV movement, so the coupon is collected exactly when fresh collateral information is priced
 * @dev Senior flows execute at settlement boundaries under the oracle-gated queues, so the committed senior NAV is the whole window's accrual base, and every settlement folds the coupon into it: the senior compounds at the collateral's information cadence
 * @dev Senior capital that exits between settlements is absent from the committed NAV at settlement, so it never collects the window's coupon and the junior buffer is never charged for capital that left
 * @dev The junior tranche is the residual claimant: the excess yield above the coupon pays the LPT liquidity premium (the capped LPT YDM output) and the junior tranche keeps the complement
 * @dev A market with a disabled junior tranche fixes the LPT yield share configuration at 100% so the liquidity premium consumes the entire excess yield, and the coupon is paid from collateral gains only (a capped rate rather than an underwritten one)
 * @dev NOTE: The shared jtProtocolFeeWAD configuration is inert in this flavor and required zero at initialization: JT's income is its yield share of the excess (the residual-form risk premium), charged jtYieldShareProtocolFeeWAD, and the impermanent loss repayment is never fee'd
 */
contract RoycoDayFixedRateAccountant is IRoycoDayFixedRateAccountant, RoycoDayAccountant {
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for uint256;
    using DispatchLogic for address;

    /// @dev Storage slot for RoycoDayFixedRateAccountantState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoDayFixedRateAccountantState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _ROYCO_DAY_FIXED_RATE_ACCOUNTANT_STORAGE_SLOT = 0x002143d04b0cc6a83f11047cafde835b9266aff7030d57aeafd685df983d3e00;

    // =============================
    // Initialization Functions
    // =============================

    /// @notice Initializes the Royco accountant state
    /// @param _params The initialization parameters for the Royco accountant
    function initialize(RoycoDayFixedRateAccountantInitParams calldata _params) external initializer {
        // Initialize the base state of the accountant
        __RoycoDayAccountant_init(_params.standardParams);

        // Validate the fixed rate accountant initialization parameters
        // Ensure that the junior tranche protocol fee is zero: the JT keeps a portion or all of the excess yield after the ST is paid its fixed coupon, so its fee is charged using jtYieldShareProtocolFeeWAD
        require(_params.standardParams.jtProtocolFeeWAD == 0, INVALID_PROTOCOL_FEE_CONFIG());
        // Ensure that the max LPT yield share does not exceed 100% of the excess yield, so the liquidity premium always fits within the excess it is carved from
        require(_params.maxLPTYieldShareWAD <= WAD, INVALID_MAX_YIELD_SHARE_CONFIG());

        // Initialize the fixed rate accountant and YDM state
        RoycoDayFixedRateAccountantState storage $ = _getRoycoDayFixedRateAccountantStorage();

        // Set the fields in slot 0 of storage
        $.lptYDM = _params.lptYDM;
        $.maxLPTYieldShareWAD = _params.maxLPTYieldShareWAD;
        emit LiquidityProviderTrancheYDMUpdated(_params.lptYDM);
        emit MaxLPTYieldShareUpdated(_params.maxLPTYieldShareWAD);

        // Set the fields in slot 1 of storage (the time-weighted yield share accumulator is zero-initialized)
        $.stFixedRatePerSecondWAD = _params.stFixedRatePerSecondWAD;
        // Open the first coupon accrual window at initialization (the genesis seed commits the first senior NAV in the same transaction)
        $.lastCouponSettlementTimestamp = uint32(block.timestamp);
        emit SeniorTrancheFixedRateUpdated(_params.stFixedRatePerSecondWAD);

        // Initialize the LPT YDM for this market
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
        // Get the storage pointers to the accountant and fixed rate accountant state
        RoycoDayAccountantState storage $_accountant = _getRoycoDayAccountantStorage();
        RoycoDayFixedRateAccountantState storage $ = _getRoycoDayFixedRateAccountantStorage();

        // Accrue the LPT yield share, then preview the synchronization of the tranche NAVs and the JT impermanent loss
        MarketState initialMarketState;
        bool premiumsPaid;
        NAV_UNIT jtImpermanentLossErased;
        uint128 twLPTYieldShareAccruedWAD = _accrueLPTYieldShare();
        (state, initialMarketState, premiumsPaid, jtImpermanentLossErased) = _previewSyncTrancheAccounting(_collateralNAV, twLPTYieldShareAccruedWAD);

        // The LPT liquidity premium was paid out of the excess yield
        if (premiumsPaid) {
            // Reset the accumulator and update the last premium payment timestamp
            delete $.twLPTYieldShareAccruedWAD;
            $.lastPremiumPaymentTimestamp = uint32(block.timestamp);
        }

        // A collateral NAV movement means fresh collateral information was priced, so the sync settled the coupon and a new accrual window opens
        // Whatever the gain and the junior buffer could not fund is forgiven, so a window never carries a coupon shortfall forward
        if (_collateralNAV != $_accountant.lastCollateralNAV) $.lastCouponSettlementTimestamp = uint32(block.timestamp);

        // Checkpoint the resulting market state, mark-to-market senior/junior NAVs, and the JT impermanent loss
        // The liquidity provider tranche raw NAV is committed subsequently since it is composed of ST shares, which are dependenent on the final ST effective NAV and total share supply
        $_accountant.lastMarketState = state.marketState;
        $_accountant.lastCollateralNAV = _collateralNAV;
        $_accountant.lastSTEffectiveNAV = state.stEffectiveNAV;
        $_accountant.lastJTEffectiveNAV = state.jtEffectiveNAV;
        $_accountant.lastJTImpermanentLoss = state.jtImpermanentLoss;

        // If the market transitioned from a perpetual to a fixed-term state, set the end timestamp of the fixed-term
        if (initialMarketState == MarketState.PERPETUAL && state.marketState == MarketState.FIXED_TERM) {
            emit FixedTermCommenced(($_accountant.fixedTermEndTimestamp = state.fixedTermEndTimestamp));
        } else if (initialMarketState == MarketState.FIXED_TERM && state.marketState == MarketState.PERPETUAL) {
            // Reset the fixed-term end timestamp
            delete $_accountant.fixedTermEndTimestamp;
            emit FixedTermEnded();
        }

        // If the JT IL was erased, signal the resetting
        if (jtImpermanentLossErased != ZERO_NAV_UNITS) emit JuniorTrancheImpermanentLossReset(jtImpermanentLossErased);
    }

    /// @inheritdoc IRoycoDayAccountant
    function previewSyncTrancheAccounting(NAV_UNIT _collateralNAV) public view override(IRoycoDayAccountant) returns (SyncedAccountingState memory state) {
        uint128 twLPTYieldShareAccruedWAD = _previewLPTYieldShareAccrual();
        (state,,,) = _previewSyncTrancheAccounting(_collateralNAV, twLPTYieldShareAccruedWAD);
    }

    // =============================
    // Internal NAV Synchronization and Accrual Functions
    // =============================

    /**
     * @notice Synchronizes all tranche NAVs and the JT impermanent loss based on unrealized PNLs of the underlying investment(s)
     * @param _collateralNAV The current pure value of the coinvested collateral backing the senior and junior tranches
     * @param _twLPTYieldShareAccruedWAD The currently accrued time-weighted LPT yield share (LPT YDM output) since the last premium payment, scaled to WAD precision
     * @return state A struct containing all mark-to-market NAV, JT impermanent loss, LPT liquidity premium, and fee data after executing the sync
     * @return initialMarketState The initial state the market was in before the synchronization
     * @return premiumsPaid A boolean indicating whether the LPT liquidity premium was paid out of the excess yield
     * @return jtImpermanentLossErased The amount of JT coverage loss erased (reset to 0)
     */
    function _previewSyncTrancheAccounting(
        NAV_UNIT _collateralNAV,
        uint256 _twLPTYieldShareAccruedWAD
    )
        internal
        view
        returns (SyncedAccountingState memory state, MarketState initialMarketState, bool premiumsPaid, NAV_UNIT jtImpermanentLossErased)
    {
        // Get the storage pointers to the accountant and fixed rate accountant state
        RoycoDayAccountantState storage $_accountant = _getRoycoDayAccountantStorage();
        RoycoDayFixedRateAccountantState storage $ = _getRoycoDayFixedRateAccountantStorage();

        // The market state that this sync transitions from
        initialMarketState = $_accountant.lastMarketState;
        // Cache the last committed effective NAVs and JT impermanent loss: these are the running accumulators the waterfall settles against
        NAV_UNIT stEffectiveNAV = $_accountant.lastSTEffectiveNAV;
        NAV_UNIT jtEffectiveNAV = $_accountant.lastJTEffectiveNAV;
        NAV_UNIT jtImpermanentLoss = $_accountant.lastJTImpermanentLoss;
        // The liquidity premium and protocol fees accrued by this sync, settled by the mark-to-market step below
        NAV_UNIT lptLiquidityPremium;
        NAV_UNIT stProtocolFee;
        NAV_UNIT jtProtocolFee;
        NAV_UNIT lptProtocolFee;
        // Cache the last committed collateral NAV: the reference the unrealized PNL since the last sync is measured against
        NAV_UNIT lastCollateralNAV = $_accountant.lastCollateralNAV;
        // The coupon owed to the senior tranche: the fixed rate applied to its committed effective NAV over the window since the last settlement, owed only when a collateral's price changes
        NAV_UNIT stCouponDue = (_collateralNAV != lastCollateralNAV)
            ? stEffectiveNAV.mulDiv(($.stFixedRatePerSecondWAD * (block.timestamp - $.lastCouponSettlementTimestamp)), WAD, Math.Rounding.Floor)
            : ZERO_NAV_UNITS;

        /// @dev STEP_APPLY_PNL_WATERFALL: Settle the collateral's unrealized PNL through the tranche waterfall: a loss is absorbed junior-first before the coupon settles, while a gain settles the coupon first, then repays the JT impermanent loss and distributes the excess yield
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

            /// @dev STEP_SETTLE_ST_COUPON: The coupon is settled after the loss waterfall, so the junior buffer absorbs principal losses before it funds senior yield
            // A markdown sync carries no gain, so the whole coupon is funded from what remains of JT's buffer: the transfer is permanent junior compensation to the senior, never impermanent loss, and the coupon beyond the buffer is forgiven
            NAV_UNIT couponPaid = RoycoUnitsMath.min(stCouponDue, jtEffectiveNAV);
            if (couponPaid != ZERO_NAV_UNITS) {
                // Compute the protocol fee taken on the coupon if it is not attributable to any rounding/dust
                if (couponPaid > $_accountant.dustTolerance) stProtocolFee = couponPaid.mulDiv($_accountant.stProtocolFeeWAD, WAD, Math.Rounding.Floor);
                jtEffectiveNAV = (jtEffectiveNAV - couponPaid);
                stEffectiveNAV = (stEffectiveNAV + couponPaid);
            }
        } else if (_collateralNAV > lastCollateralNAV) {
            // The unrealized gain of the underlying investment since the last NAV checkpoint
            NAV_UNIT gain = (_collateralNAV - lastCollateralNAV);

            /// @dev STEP_SETTLE_ST_COUPON: The coupon is settled off the top of the gain, ahead of the JT impermanent loss repayment and the excess yield distribution
            // Any shortfall is funded from JT's buffer up to its full depth: the transfer is permanent junior compensation to the senior, never impermanent loss, and the coupon beyond the buffer is forgiven
            if (stCouponDue != ZERO_NAV_UNITS) {
                NAV_UNIT couponFromGain = RoycoUnitsMath.min(gain, stCouponDue);
                NAV_UNIT couponFromJT = RoycoUnitsMath.min((stCouponDue - couponFromGain), jtEffectiveNAV);
                NAV_UNIT couponPaid = (couponFromGain + couponFromJT);
                // Compute the protocol fee taken on the coupon if it is not attributable to any rounding/dust
                if (couponPaid > $_accountant.dustTolerance) {
                    stProtocolFee = (couponFromGain + couponFromJT).mulDiv($_accountant.stProtocolFeeWAD, WAD, Math.Rounding.Floor);
                }
                jtEffectiveNAV = (jtEffectiveNAV - couponFromJT);
                stEffectiveNAV = (stEffectiveNAV + couponPaid);
                gain = (gain - couponFromGain);
            }

            /// @dev STEP_REPAY_JT_IMPERMANENT_LOSS: Any prior transient loss booked by the JT from coverage provided or its own loss is repaid after the coupon
            // The repayment is restoration, never yield, so it is never has a fee
            if (jtImpermanentLoss != ZERO_NAV_UNITS) {
                NAV_UNIT jtImpermanentLossRepayment = RoycoUnitsMath.min(gain, jtImpermanentLoss);
                jtImpermanentLoss = (jtImpermanentLoss - jtImpermanentLossRepayment);
                jtEffectiveNAV = (jtEffectiveNAV + jtImpermanentLossRepayment);
                gain = (gain - jtImpermanentLossRepayment);
            }

            /// @dev STEP_DISTRIBUTE_EXCESS_YIELD: The gain remaining above the coupon and the impermanent loss repayment is junior-bound: the LPT liquidity premium is carved from it and the junior tranche keeps the complement as the residual claimant
            if (gain != ZERO_NAV_UNITS) {
                // Mark yield as distributed if the excess is not attributable to any rounding/dust
                if (gain > $_accountant.dustTolerance) premiumsPaid = true;
                // The liquidity premium is paid on its own since the coupon replaces the risk premium, so the elapsed window is measured since the last premium payment
                uint256 elapsedSinceLastPremiumPayment = (block.timestamp - $.lastPremiumPaymentTimestamp);
                // If the last premium payment happened in the same block, use the instantaneous yield share
                // Else, use the time-weighted average yield share since the last premium payment
                if (elapsedSinceLastPremiumPayment == 0) {
                    // Set the elapsed time to 1 second (instantaneous)
                    elapsedSinceLastPremiumPayment = 1 seconds;
                    // The LPT YDM is driven by the market's liquidity utilization: the LPT liquidity premium scales with how utilized the LPT market-making inventory is
                    _twLPTYieldShareAccruedWAD = Math.min(
                        IYDM($.lptYDM)
                            .previewYieldShare(
                                initialMarketState,
                                UtilizationLogic._computeLiquidityUtilization(
                                    $_accountant.lastSTEffectiveNAV, $_accountant.minLiquidityWAD, $_accountant.lastLPTRawNAV
                                )
                            ),
                        $.maxLPTYieldShareWAD
                    );
                }
                // Compute the liquidity premium based on the yield share and time elapsed since the last premium payment
                lptLiquidityPremium = gain.mulDiv(_twLPTYieldShareAccruedWAD, (elapsedSinceLastPremiumPayment * WAD), Math.Rounding.Floor);
                // The liquidity premium can never exceed the excess yield: the LPT yield share is capped at 100% of the excess it is carved from
                require(lptLiquidityPremium <= gain, LIQUIDITY_PREMIUM_EXCEEDS_EXCESS_YIELD());
                // Pay the liquidity premium to LPT: it is minted as senior shares to LPT, so it remains a senior claim within ST effective NAV (coverage-neutral) and is carved out of the excess only to size JT's retained yield and protocol fee
                if (lptLiquidityPremium != ZERO_NAV_UNITS) {
                    // Compute the protocol fee taken on the yield share accrual if it is not attributable to any rounding/dust
                    if (premiumsPaid) {
                        lptProtocolFee = lptLiquidityPremium.mulDiv($_accountant.lptYieldShareProtocolFeeWAD, WAD, Math.Rounding.Floor);
                    }
                    gain = (gain - lptLiquidityPremium);
                }
                /// @dev STEP_APPLY_JT_EXCESS_YIELD: JT keeps the excess yield remaining after the liquidity premium carve as its yield share of the excess: the residual-form risk premium for underwriting the coupon, the complement always exhausts the gain
                if (gain != ZERO_NAV_UNITS) {
                    // Compute the protocol fee taken on the yield share accrual if it is not attributable to any rounding/dust
                    if (premiumsPaid) jtProtocolFee = gain.mulDiv($_accountant.jtYieldShareProtocolFeeWAD, WAD, Math.Rounding.Floor);
                    // Book the gains to the JT
                    jtEffectiveNAV = (jtEffectiveNAV + gain);
                }
                // Book the liquidity premium to the ST as a senior claim now owned by LPT (coverage neutral, so the two-term NAV conservation holds)
                // The liquidity premium is used to mint ST shares to the LPT
                stEffectiveNAV = (stEffectiveNAV + lptLiquidityPremium);
            }
        }

        // Enforce the NAV conservation invariant
        require((_collateralNAV == (stEffectiveNAV + jtEffectiveNAV)), NAV_CONSERVATION_VIOLATION());

        /// @dev STEP_APPLY_MARKET_STATE_TRANSITION: Marshal the post-sync accounting state, then apply the market state transition resulting from this sync
        // Marshal the post-sync state and return it to the caller
        // NOTE: The liquidity provider tranche raw NAV and utilization are zero placeholders that the kernel refreshes after committing the fresh mark
        // NOTE: The market state and fixed-term end timestamp are completed by the shared state transition
        state = SyncedAccountingState({
            marketState: initialMarketState,
            collateralNAV: _collateralNAV,
            lptRawNAV: ZERO_NAV_UNITS,
            stEffectiveNAV: stEffectiveNAV,
            jtEffectiveNAV: jtEffectiveNAV,
            jtImpermanentLoss: jtImpermanentLoss,
            lptLiquidityPremium: lptLiquidityPremium,
            stProtocolFee: stProtocolFee,
            jtProtocolFee: jtProtocolFee,
            lptProtocolFee: lptProtocolFee,
            coverageUtilizationWAD: UtilizationLogic._computeCoverageUtilization(_collateralNAV, $_accountant.minCoverageWAD, jtEffectiveNAV),
            liquidityUtilizationWAD: 0,
            fixedTermEndTimestamp: 0,
            minCoverageWAD: $_accountant.minCoverageWAD,
            coverageLiquidationUtilizationWAD: $_accountant.coverageLiquidationUtilizationWAD,
            minLiquidityWAD: $_accountant.minLiquidityWAD
        });

        // NOTE: A fixed-term commit structurally carries a zero liquidity premium and zero junior and liquidity fee legs since the excess yield only flows once the JT IL is repaid within the dust tolerance, only the coupon's senior fee can accrue
        jtImpermanentLossErased = _applyStateTransition(state, initialMarketState);
    }

    /**
     * @notice Accrues the LPT yield share since the last premium payment
     * @dev Advances the adaptive YDM and gets the instantaneous yield share, capped at its configured maximum, then weights it by the time elapsed since the last accrual
     * @return twLPTYieldShareAccruedWAD The updated time-weighted LPT yield share since the last premium payment
     */
    function _accrueLPTYieldShare() internal returns (uint128 twLPTYieldShareAccruedWAD) {
        // Get the storage pointers to the accountant and fixed rate accountant state
        RoycoDayAccountantState storage $_accountant = _getRoycoDayAccountantStorage();
        RoycoDayFixedRateAccountantState storage $ = _getRoycoDayFixedRateAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $.lastYieldShareAccrualTimestamp;
        if (lastUpdate == 0) {
            // Initialize the checkpoint timestamps if this is the first accrual
            $.lastYieldShareAccrualTimestamp = uint32(block.timestamp);
            $.lastPremiumPaymentTimestamp = uint32(block.timestamp);
            return 0;
        }

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return $.twLPTYieldShareAccruedWAD;

        // Advance the adaptive YDM and read the instantaneous yield share, capped at its configured maximum
        uint256 liquidityUtilizationWAD =
            UtilizationLogic._computeLiquidityUtilization($_accountant.lastSTEffectiveNAV, $_accountant.minLiquidityWAD, $_accountant.lastLPTRawNAV);
        uint256 lptYieldShareWAD = Math.min(IYDM($.lptYDM).yieldShare($_accountant.lastMarketState, liquidityUtilizationWAD), $.maxLPTYieldShareWAD);

        // Accrue the time-weighted yield share since the last tranche interaction
        twLPTYieldShareAccruedWAD = ($.twLPTYieldShareAccruedWAD += uint128(lptYieldShareWAD * elapsed));
        $.lastYieldShareAccrualTimestamp = uint32(block.timestamp);

        emit LPTYieldShareAccrued(lptYieldShareWAD, twLPTYieldShareAccruedWAD);
    }

    /**
     * @notice Computes and returns the currently accrued LPT yield share since the last premium payment
     * @dev Gets the instantaneous yield share, capped at its configured maximum, and weights it by the time elapsed since the last accrual
     * @return twLPTYieldShareAccruedWAD The updated time-weighted LPT yield share since the last premium payment
     */
    function _previewLPTYieldShareAccrual() internal view returns (uint128 twLPTYieldShareAccruedWAD) {
        // Get the storage pointers to the accountant and fixed rate accountant state
        RoycoDayAccountantState storage $_accountant = _getRoycoDayAccountantStorage();
        RoycoDayFixedRateAccountantState storage $ = _getRoycoDayFixedRateAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $.lastYieldShareAccrualTimestamp;
        if (lastUpdate == 0) return 0;

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return $.twLPTYieldShareAccruedWAD;

        // Read the instantaneous yield share, capped at its configured maximum
        uint256 liquidityUtilizationWAD =
            UtilizationLogic._computeLiquidityUtilization($_accountant.lastSTEffectiveNAV, $_accountant.minLiquidityWAD, $_accountant.lastLPTRawNAV);
        uint256 lptYieldShareWAD = Math.min(IYDM($.lptYDM).previewYieldShare($_accountant.lastMarketState, liquidityUtilizationWAD), $.maxLPTYieldShareWAD);

        // Apply the accrual of the yield share to the accumulator, weighted by the time elapsed
        twLPTYieldShareAccruedWAD = ($.twLPTYieldShareAccruedWAD + uint128(lptYieldShareWAD * elapsed));
    }

    // =============================
    // Administrative Functions
    // =============================

    /// @inheritdoc IRoycoDayFixedRateAccountant
    function setSeniorTrancheFixedRate(uint64 _stFixedRatePerSecondWAD) external override(IRoycoDayFixedRateAccountant) restricted withSyncedAccounting {
        // The modifier's pre-call sync banked the elapsed window at the outgoing rate, so the new rate only applies going forward
        _getRoycoDayFixedRateAccountantStorage().stFixedRatePerSecondWAD = _stFixedRatePerSecondWAD;
        emit SeniorTrancheFixedRateUpdated(_stFixedRatePerSecondWAD);
    }

    /// @inheritdoc IRoycoDayFixedRateAccountant
    function setLiquidityProviderTrancheYDM(
        address _lptYDM,
        bytes calldata _lptYDMInitializationData
    )
        external
        override(IRoycoDayFixedRateAccountant)
        restricted
    {
        // Best-effort sync to settle unrealized PNL under the outgoing LPT YDM
        // NOTE: A reverting sync is tolerated since this setter is the only recovery path from a sync-bricking LPT YDM
        _getRoycoDayAccountantStorage().kernel._tryExecute(abi.encodeCall(IRoycoDayKernel.syncTrancheAccountingFromAccountant, ()));
        // Initialize and set the new LPT YDM for this market
        _initializeYDM(_lptYDM, _lptYDMInitializationData);
        _getRoycoDayFixedRateAccountantStorage().lptYDM = _lptYDM;
        emit LiquidityProviderTrancheYDMUpdated(_lptYDM);
    }

    /// @inheritdoc IRoycoDayFixedRateAccountant
    function setMaxLPTYieldShare(uint64 _maxLPTYieldShareWAD) external override(IRoycoDayFixedRateAccountant) restricted withSyncedAccounting {
        // Ensure that the max LPT yield share does not exceed 100% of the excess yield, so the liquidity premium always fits within the excess it is carved from
        require(_maxLPTYieldShareWAD <= WAD, INVALID_MAX_YIELD_SHARE_CONFIG());
        _getRoycoDayFixedRateAccountantStorage().maxLPTYieldShareWAD = _maxLPTYieldShareWAD;
        emit MaxLPTYieldShareUpdated(_maxLPTYieldShareWAD);
    }

    // =============================
    // Accountant State Accessor Functions
    // =============================

    /// @inheritdoc IRoycoDayFixedRateAccountant
    function getRoycoDayFixedRateAccountantState() external view override(IRoycoDayFixedRateAccountant) returns (RoycoDayFixedRateAccountantState memory) {
        return _getRoycoDayFixedRateAccountantStorage();
    }

    /**
     * @notice Returns a storage pointer to the RoycoDayFixedRateAccountantState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the fixed rate accountant's state
     */
    function _getRoycoDayFixedRateAccountantStorage() internal pure returns (RoycoDayFixedRateAccountantState storage $) {
        assembly ("memory-safe") {
            $.slot := _ROYCO_DAY_FIXED_RATE_ACCOUNTANT_STORAGE_SLOT
        }
    }
}
