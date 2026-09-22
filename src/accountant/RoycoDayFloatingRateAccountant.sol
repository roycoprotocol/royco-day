// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { IYDM } from "../interfaces/IYDM.sol";
import { IRoycoDayAccountant } from "../interfaces/accountant/IRoycoDayAccountant.sol";
import { IRoycoDayFloatingRateAccountant } from "../interfaces/accountant/IRoycoDayFloatingRateAccountant.sol";
import { MAX_PROTOCOL_FEE_WAD, WAD, ZERO_NAV_UNITS } from "../libraries/Constants.sol";
import { DispatchMode, MarketState, NAV_UNIT, SyncedAccountingState } from "../libraries/Types.sol";
import { Math, RoycoUnitsMath } from "../libraries/Units.sol";
import { DispatchLogic } from "../libraries/logic/DispatchLogic.sol";
import { UtilizationLogic } from "../libraries/logic/UtilizationLogic.sol";
import { RoycoDayAccountant } from "./base/RoycoDayAccountant.sol";

/**
 * @title RoycoDayFloatingRateAccountant
 * @author Shivaansh Kapoor, Ankur Dubey, Tomer Ganor
 * @notice Performs and tracks the accounting, coverage, and liquidity operations and requirements for a Royco market
 * @notice Responsible for marking tranche NAVs to market, tracking the JT impermanent loss, distributing yield via the JT and LPT YDM, and computing protocol fees
 */
contract RoycoDayFloatingRateAccountant is IRoycoDayFloatingRateAccountant, RoycoDayAccountant {
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for uint256;
    using DispatchLogic for address;

    /// @dev Storage slot for RoycoDayFloatingRateAccountantState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoDayFloatingRateAccountantState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _ROYCO_DAY_FLOATING_RATE_ACCOUNTANT_STORAGE_SLOT = 0xae6076c33ea5a1b3d2cbe3e62849f92c77b936283ae8fb093140099bce32e600;

    // =============================
    // Initialization Functions
    // =============================

    /// @notice Initializes the Royco accountant state
    /// @param _params The initialization parameters for the Royco accountant
    function initialize(RoycoDayFloatingRateAccountantInitParams calldata _params) external initializer {
        // Initialize the base state of the accountant
        __RoycoDayAccountant_init(_params.standardParams);

        // Validate the floating rate accountant initialization parameters
        // Ensure that the YDMs are not identical: each tranche requires its own YDM instance: the YDMs are initialized per market and the adaptive models keep per-market curve state, so sharing one instance would corrupt both premiums by interleaving coverage and liquidity driven updates
        require(_params.jtYDM != _params.lptYDM, YDMS_CANNOT_BE_IDENTICAL());
        // Ensure that the max JT and LPT yield shares do not sum to greater than 100% of senior appreciation
        _validateYieldShareConfig(_params.maxJTYieldShareWAD, _params.maxLPTYieldShareWAD);

        // Initialize the floating rate accountant and YDM state
        RoycoDayFloatingRateAccountantState storage $_floatingRate = _getRoycoDayFloatingRateAccountantStorage();

        // Set the fields in slot 0 of storage
        $_floatingRate.jtYDM = _params.jtYDM;
        $_floatingRate.maxJTYieldShareWAD = _params.maxJTYieldShareWAD;
        emit JuniorTrancheYDMUpdated(_params.jtYDM);

        // Set the fields in slot 1 of storage (the time-weighted yield share accumulators in slot 2 are zero-initialized)
        $_floatingRate.lptYDM = _params.lptYDM;
        $_floatingRate.maxLPTYieldShareWAD = _params.maxLPTYieldShareWAD;
        emit LiquidityProviderTrancheYDMUpdated(_params.lptYDM);
        emit MaxYieldSharesUpdated(_params.maxJTYieldShareWAD, _params.maxLPTYieldShareWAD);

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
        // Get the storage pointers to the accountant and floating rate accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        RoycoDayFloatingRateAccountantState storage $_floatingRate = _getRoycoDayFloatingRateAccountantStorage();

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
            delete $_floatingRate.twJTYieldShareAccruedWAD;
            delete $_floatingRate.twLPTYieldShareAccruedWAD;
            $_floatingRate.lastPremiumPaymentTimestamp = uint32(block.timestamp);
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
    }

    /// @inheritdoc IRoycoDayAccountant
    function previewSyncTrancheAccounting(NAV_UNIT _collateralNAV) public view override(IRoycoDayAccountant) returns (SyncedAccountingState memory state) {
        (uint128 twJTYieldShareAccruedWAD, uint128 twLPTYieldShareAccruedWAD) = _previewPremiumYieldShareAccrual();
        (state,,,) = _previewSyncTrancheAccounting(_collateralNAV, twJTYieldShareAccruedWAD, twLPTYieldShareAccruedWAD);
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
        // Get the storage pointers to the accountant and floating rate accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        RoycoDayFloatingRateAccountantState storage $_floatingRate = _getRoycoDayFloatingRateAccountantStorage();

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
                    uint256 elapsedSinceLastPremiumPayments = (block.timestamp - $_floatingRate.lastPremiumPaymentTimestamp);
                    // If the last premium payments happened in the same block, use the instantaneous yield shares
                    // Else, use the time-weighted average yield shares since the last premium payments
                    if (elapsedSinceLastPremiumPayments == 0) {
                        // Set the elapsed time to 1 second (instantaneous)
                        elapsedSinceLastPremiumPayments = 1 seconds;
                        // Query the instantaneous yield shares for the JT and LPT
                        _twJTYieldShareAccruedWAD = Math.min(
                            IYDM($_floatingRate.jtYDM)
                                .previewYieldShare(
                                    initialMarketState,
                                    UtilizationLogic._computeCoverageUtilization($.lastCollateralNAV, $.minCoverageWAD, $.lastJTEffectiveNAV)
                                ),
                            $_floatingRate.maxJTYieldShareWAD
                        );
                        // The LPT YDM is driven by the market's liquidity utilization: the LPT liquidity premium scales with how utilized the LPT market-making inventory is
                        _twLPTYieldShareAccruedWAD = Math.min(
                            IYDM($_floatingRate.lptYDM)
                                .previewYieldShare(
                                    initialMarketState, UtilizationLogic._computeLiquidityUtilization($.lastSTEffectiveNAV, $.minLiquidityWAD, $.lastLPTRawNAV)
                                ),
                            $_floatingRate.maxLPTYieldShareWAD
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
            // 2. There is no senior capital to protect in this market
            // 3. The junior buffer is wiped (partially collateralized or a total wipe), so its dead restoration claim is extinguished, ST needs to be able to withdraw to avoid/book losses, and the YDM needs to kick in to reinstate proper collateralization
            // 4. The JT impermanent loss is within the dust tolerance (fully repaid or dust-sized), so JT provides its loss-absorption buffer and needs no observation period: dust ST or JT losses (eg. rounding in the underlying NAVs) never lock or keep locking the market
            // 5. The current fixed-term has elapsed, so the transient JT observation period is complete
            // 6. The coverage utilization breached the liquidation threshold, so the market forces open senior exits
            // 7. The market is still within its post-deployment fixed-term grace period, so it cannot enter it no matter what
            if (
                fixedTermDurationSeconds == 0 || stEffectiveNAV == ZERO_NAV_UNITS || jtEffectiveNAV == ZERO_NAV_UNITS || jtImpermanentLoss <= dustTolerance
                    || (initialMarketState == MarketState.FIXED_TERM && fixedTermEndTimestamp <= block.timestamp)
                    || coverageUtilizationWAD >= coverageLiquidationUtilizationWAD || block.timestamp < $.fixedTermCommenceableAtTimestamp
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
        // Get the storage pointers to the accountant and floating rate accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        RoycoDayFloatingRateAccountantState storage $_floatingRate = _getRoycoDayFloatingRateAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $_floatingRate.lastYieldShareAccrualTimestamp;
        if (lastUpdate == 0) {
            // Initialize the checkpoint timestamps if this is the first accrual
            $_floatingRate.lastYieldShareAccrualTimestamp = uint32(block.timestamp);
            $_floatingRate.lastPremiumPaymentTimestamp = uint32(block.timestamp);
            return (0, 0);
        }

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return ($_floatingRate.twJTYieldShareAccruedWAD, $_floatingRate.twLPTYieldShareAccruedWAD);

        // Advance the adaptive YDMs and read each instantaneous yield share, capped at its configured maximum
        (uint256 coverageUtilizationWAD, uint256 liquidityUtilizationWAD) = _computeUtilizations();
        uint256 jtYieldShareWAD = Math.min(IYDM($_floatingRate.jtYDM).yieldShare($.lastMarketState, coverageUtilizationWAD), $_floatingRate.maxJTYieldShareWAD);
        uint256 lptYieldShareWAD =
            Math.min(IYDM($_floatingRate.lptYDM).yieldShare($.lastMarketState, liquidityUtilizationWAD), $_floatingRate.maxLPTYieldShareWAD);

        // Accrue the time-weighted yield shares since the last tranche interaction
        twJTYieldShareAccruedWAD = ($_floatingRate.twJTYieldShareAccruedWAD += uint128(jtYieldShareWAD * elapsed));
        twLPTYieldShareAccruedWAD = ($_floatingRate.twLPTYieldShareAccruedWAD += uint128(lptYieldShareWAD * elapsed));
        $_floatingRate.lastYieldShareAccrualTimestamp = uint32(block.timestamp);

        emit YieldSharesAccrued(jtYieldShareWAD, twJTYieldShareAccruedWAD, lptYieldShareWAD, twLPTYieldShareAccruedWAD);
    }

    /**
     * @notice Computes and returns the currently accrued JT and LPT yield shares since the last premium payment
     * @dev Gets the instantaneous yield shares, each capped at its configured maximum, and weights them by the time elapsed since the last accrual
     * @return twJTYieldShareAccruedWAD The updated time-weighted JT yield share since the last premium payment
     * @return twLPTYieldShareAccruedWAD The updated time-weighted LPT yield share since the last premium payment
     */
    function _previewPremiumYieldShareAccrual() internal view returns (uint128 twJTYieldShareAccruedWAD, uint128 twLPTYieldShareAccruedWAD) {
        // Get the storage pointers to the accountant and floating rate accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        RoycoDayFloatingRateAccountantState storage $_floatingRate = _getRoycoDayFloatingRateAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $_floatingRate.lastYieldShareAccrualTimestamp;
        if (lastUpdate == 0) return (0, 0);

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return ($_floatingRate.twJTYieldShareAccruedWAD, $_floatingRate.twLPTYieldShareAccruedWAD);

        // Read each instantaneous yield share, capped at its configured maximum
        (uint256 coverageUtilizationWAD, uint256 liquidityUtilizationWAD) = _computeUtilizations();
        uint256 jtYieldShareWAD =
            Math.min(IYDM($_floatingRate.jtYDM).previewYieldShare($.lastMarketState, coverageUtilizationWAD), $_floatingRate.maxJTYieldShareWAD);
        uint256 lptYieldShareWAD =
            Math.min(IYDM($_floatingRate.lptYDM).previewYieldShare($.lastMarketState, liquidityUtilizationWAD), $_floatingRate.maxLPTYieldShareWAD);

        // Apply the accrual of the yield shares to the accumulators, weighted by the time elapsed
        twJTYieldShareAccruedWAD = ($_floatingRate.twJTYieldShareAccruedWAD + uint128(jtYieldShareWAD * elapsed));
        twLPTYieldShareAccruedWAD = ($_floatingRate.twLPTYieldShareAccruedWAD + uint128(lptYieldShareWAD * elapsed));
    }

    // =============================
    // Administrative Functions
    // =============================

    /// @inheritdoc IRoycoDayFloatingRateAccountant
    function setJuniorTrancheYDM(address _jtYDM, bytes calldata _jtYDMInitializationData) external override(IRoycoDayFloatingRateAccountant) restricted {
        RoycoDayFloatingRateAccountantState storage $_floatingRate = _getRoycoDayFloatingRateAccountantStorage();
        // The junior and liquidity provider tranche YDMs must remain distinct: a shared instance would corrupt both premiums by interleaving coverage and liquidity driven updates
        require(_jtYDM != $_floatingRate.lptYDM, YDMS_CANNOT_BE_IDENTICAL());
        // Best-effort sync to settle unrealized PNL under the outgoing JT YDM
        // NOTE: A reverting sync is tolerated since this setter is the only recovery path from a sync-bricking JT YDM
        _getRoycoDayAccountantStorage().kernel._tryExecute(abi.encodeCall(IRoycoDayKernel.syncTrancheAccountingFromAccountant, ()));
        // Initialize and set the new JT YDM for this market
        _initializeYDM(_jtYDM, _jtYDMInitializationData);
        $_floatingRate.jtYDM = _jtYDM;
        emit JuniorTrancheYDMUpdated(_jtYDM);
    }

    /// @inheritdoc IRoycoDayFloatingRateAccountant
    function setLiquidityProviderTrancheYDM(
        address _lptYDM,
        bytes calldata _lptYDMInitializationData
    )
        external
        override(IRoycoDayFloatingRateAccountant)
        restricted
    {
        RoycoDayFloatingRateAccountantState storage $_floatingRate = _getRoycoDayFloatingRateAccountantStorage();
        // The junior and liquidity provider tranche YDMs must remain distinct: a shared instance would corrupt both premiums by interleaving coverage and liquidity driven updates
        require(_lptYDM != $_floatingRate.jtYDM, YDMS_CANNOT_BE_IDENTICAL());
        // Best-effort sync to settle unrealized PNL under the outgoing LPT YDM
        // NOTE: A reverting sync is tolerated since this setter is the only recovery path from a sync-bricking LPT YDM
        _getRoycoDayAccountantStorage().kernel._tryExecute(abi.encodeCall(IRoycoDayKernel.syncTrancheAccountingFromAccountant, ()));
        // Initialize and set the new LPT YDM for this market
        _initializeYDM(_lptYDM, _lptYDMInitializationData);
        $_floatingRate.lptYDM = _lptYDM;
        emit LiquidityProviderTrancheYDMUpdated(_lptYDM);
    }

    /// @inheritdoc IRoycoDayFloatingRateAccountant
    function setMaxYieldShares(
        uint64 _maxJTYieldShareWAD,
        uint64 _maxLPTYieldShareWAD
    )
        external
        override(IRoycoDayFloatingRateAccountant)
        restricted
        withSyncedAccounting
    {
        // Validate the new yield share configuration: the maximum JT and LPT yield shares must sum to at most 100% of senior appreciation
        _validateYieldShareConfig(_maxJTYieldShareWAD, _maxLPTYieldShareWAD);
        RoycoDayFloatingRateAccountantState storage $_floatingRate = _getRoycoDayFloatingRateAccountantStorage();
        $_floatingRate.maxJTYieldShareWAD = _maxJTYieldShareWAD;
        $_floatingRate.maxLPTYieldShareWAD = _maxLPTYieldShareWAD;
        emit MaxYieldSharesUpdated(_maxJTYieldShareWAD, _maxLPTYieldShareWAD);
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
     * @dev A failing initialization bubbles the YDM's revert verbatim through the shared dispatch primitive
     * @param _ydm The new YDM address to set
     * @param _ydmInitializationData The data used to initialize the new YDM for this market
     */
    function _initializeYDM(address _ydm, bytes calldata _ydmInitializationData) internal {
        // Ensure that the YDM is not null
        require(_ydm != address(0), NULL_ADDRESS());
        // Initialize the YDM if required
        if (_ydmInitializationData.length != 0) _ydm._dispatch(DispatchMode.EXECUTE, _ydmInitializationData);
    }

    // =============================
    // Accountant State Accessor Functions
    // =============================

    /// @inheritdoc IRoycoDayFloatingRateAccountant
    function getRoycoDayFloatingRateAccountantState()
        external
        view
        override(IRoycoDayFloatingRateAccountant)
        returns (RoycoDayFloatingRateAccountantState memory)
    {
        return _getRoycoDayFloatingRateAccountantStorage();
    }

    /**
     * @notice Returns a storage pointer to the RoycoDayFloatingRateAccountantState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the floating rate accountant's state
     */
    function _getRoycoDayFloatingRateAccountantStorage() internal pure returns (RoycoDayFloatingRateAccountantState storage $) {
        assembly ("memory-safe") {
            $.slot := _ROYCO_DAY_FLOATING_RATE_ACCOUNTANT_STORAGE_SLOT
        }
    }
}
