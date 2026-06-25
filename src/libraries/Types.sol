// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { NAV_UNIT, TRANCHE_UNIT } from "./Units.sol";

/**
 * @title MarketState
 * @notice Defines the operational state of a Royco market
 * @custom:state PERPETUAL
 *      Normal operating state where market forces govern behavior
 *      - The market is healthy (no losses over dust tolerance) or it is severely undercollateralized (liquidation coverageUtilization breach) or uncollateralized (JT_EFFECTIVE_NAV == 0 while ST_EFFECTIVE_NAV > 0)
 *      - Both tranches liquid (within coverage constraints)
 *      - Adaptive curve YDM adapts based on coverageUtilization
 * @custom:state FIXED_TERM
 *      Temporary recovery state triggered when JT provides coverage for ST drawdown
 *      - ST experienced a fully covered drawdown but the market is still healthy in terms of its liquidation coverageUtilization threshold
 *      - Fixed term that starts when JT coverage impermanent loss is first incurred
 *      - ST redemptions blocked: protects existing JT from realizing losses by ST withdrawing coverage on arbitrary volatility
 *      - JT deposits blocked: protects existing JT from realizing losses by new JT diluting them on arbitrary volatility
 *      - Adaptive curve YDM does not adapt (prevents adaptation during recovery since market forces aren't influencing coverageUtilization, underlying PNL is)
 *      - Automatically transitions to PERPETUAL when term elapses, clearing JT coverage impermanent losses
 */
enum MarketState {
    PERPETUAL,
    FIXED_TERM
}

/**
 * @title AssetClaims
 * @dev A struct representing claims on senior tranche assets, junior tranche assets, and NAV
 * @custom:field stAssets - The claim on senior tranche assets denominated in ST's tranche units
 * @custom:field jtAssets - The claim on junior tranche assets denominated in JT's tranche units
 * @custom:field nav - The net asset value of these claims in NAV units
 */
struct AssetClaims {
    TRANCHE_UNIT stAssets;
    TRANCHE_UNIT jtAssets;
    NAV_UNIT nav;
}

/**
 * @title SyncedAccountingState
 * @dev Contains all current mark-to-market NAV accounting data for the market's tranches
 * @custom:field marketState - The current state of the Royco market (perpetual or fixed term)
 * @custom:field stRawNAV - The senior tranche's current raw NAV: the pure value of its invested assets
 * @custom:field jtRawNAV - The junior tranche's current raw NAV: the pure value of its invested assets
 * @custom:field stEffectiveNAV - Senior tranche effective NAV: includes applied coverage, its share of ST yield, and uncovered losses
 * @custom:field jtEffectiveNAV - Junior tranche effective NAV: includes provided coverage, JT yield, its share of ST yield, and JT losses
 * @custom:field jtCoverageImpermanentLoss - The impermanent loss that JT has suffered after providing coverage for ST losses
 *                                   This represents the claim on capital that the junior tranche has on future ST recoveries
 * @custom:field ltLiquidityPremiumPaid - The liquidity premium accrued to the liquidity tranche on this sync: LT's share of senior yield, minted as senior tranche shares to LT (coverage-neutral)
 * @custom:field stProtocolFeeAccrued - Protocol fee taken on ST yield on this sync
 * @custom:field jtProtocolFeeAccrued - Protocol fee taken on JT yield on this sync
 * @custom:field ltProtocolFeeAccrued - Protocol fee taken on the liquidity premium (LT yield share) on this sync
 * @custom:field coverageUtilizationWAD - The current coverageUtilization of the market, scaled to WAD precision
 * @custom:field liquidityUtilizationWAD - The current liquidityUtilization of the market, scaled to WAD precision
 * @custom:field fixedTermEndTimestamp - The timestamp at which the fixed term ends. Set to 0 if the market is not in a fixed term state
 * @custom:field minCoverageWAD - The coverage percentage that the senior tranche is expected to be protected by, scaled to WAD precision
 * @custom:field betaWAD - JT's percentage sensitivity to the same downside stress that affects ST, scaled to WAD precision
 *                         For example, beta is 0 when JT is in the RFR and 1e18 (100%) when JT is in the same opportunity as senior
 * @custom:field liquidationCoverageUtilizationWAD - The liquidation coverageUtilization threshold for this market, scaled to WAD precision
 * @custom:field minLiquidityWAD - The percentage of the senior tranche NAV that must be in the liquidity tranche's market making inventory, scaled to WAD precision
 */
struct SyncedAccountingState {
    // The market's current operating state (PERPETUAL or FIXED_TERM)
    MarketState marketState;
    // The market's marked-to-market NAVs, JT coverage impermanent loss, LT liquidity premium, and fees
    NAV_UNIT stRawNAV;
    NAV_UNIT jtRawNAV;
    NAV_UNIT stEffectiveNAV;
    NAV_UNIT jtEffectiveNAV;
    NAV_UNIT jtCoverageImpermanentLoss;
    NAV_UNIT ltLiquidityPremiumPaid;
    NAV_UNIT stProtocolFeeAccrued;
    NAV_UNIT jtProtocolFeeAccrued;
    NAV_UNIT ltProtocolFeeAccrued;
    // The market's derived state metrics
    uint256 coverageUtilizationWAD;
    uint256 liquidityUtilizationWAD;
    uint32 fixedTermEndTimestamp;
    // The market's coverage configuration
    uint256 minCoverageWAD;
    uint256 betaWAD;
    uint256 liquidationCoverageUtilizationWAD;
    // The market's liquidity configuration
    uint256 minLiquidityWAD;
}

/**
 * @title AccountingCheckpoint
 * @dev A snapshot of the market's committed tranche accounting: the raw and effective NAVs alongside the JT coverage impermanent loss
 * @dev The raw and effective NAVs must satisfy the NAV conservation invariant: they must sum to the same total at wei precision
 * @custom:field stRawNAV - The senior tranche's raw NAV: the pure value of its invested assets
 * @custom:field jtRawNAV - The junior tranche's raw NAV: the pure value of its invested assets
 * @custom:field ltRawNAV - The liquidity tranche's raw NAV: the pure value of its invested assets
 * @custom:field stEffectiveNAV - The senior tranche's effective NAV: includes applied coverage, its share of ST yield, and uncovered losses
 * @custom:field jtEffectiveNAV - The junior tranche's effective NAV: includes provided coverage, JT yield, its share of ST yield, and JT losses
 * @custom:field jtCoverageImpermanentLoss - The impermanent loss that JT has suffered after providing coverage for ST losses: its claim on future ST recoveries
 */
struct AccountingCheckpoint {
    NAV_UNIT stRawNAV;
    NAV_UNIT jtRawNAV;
    NAV_UNIT ltRawNAV;
    NAV_UNIT stEffectiveNAV;
    NAV_UNIT jtEffectiveNAV;
    NAV_UNIT jtCoverageImpermanentLoss;
}

/**
 * @title PnLWaterfallParams
 * @dev The fixed inputs of the PnL attribution and settlement waterfall, alongside the raw NAVs measured against the checkpoint
 * @custom:field checkpoint - The accounting checkpoint the waterfall settles against (the last committed sync state)
 * @custom:field twJTYieldShareAccruedWAD - The time-weighted JT yield share (YDM output) accrued since the last distribution, scaled to WAD precision
 * @custom:field instantaneousJTYieldShareWAD - The instantaneous JT yield share (YDM output) consumed when the last distribution happened in the same block, scaled to WAD precision
 * @custom:field elapsedSinceLastRiskPremiumPayment - The seconds elapsed since the last risk premium payment
 * @custom:field stProtocolFeeWAD - The market's protocol fee percentage taken from ST yield, scaled to WAD precision
 * @custom:field jtProtocolFeeWAD - The market's protocol fee percentage taken from JT yield, scaled to WAD precision
 * @custom:field jtYieldShareProtocolFeeWAD - The market's protocol fee percentage taken from the yield share (risk premium), scaled to WAD precision
 * @custom:field effectiveNAVDustTolerance - The effective NAV dust tolerance: the worst-case dust bounded by the sum of the raw NAV dust tolerances
 */
struct PnLWaterfallParams {
    AccountingCheckpoint checkpoint;
    uint192 twJTYieldShareAccruedWAD;
    uint256 instantaneousJTYieldShareWAD;
    uint256 elapsedSinceLastRiskPremiumPayment;
    uint64 stProtocolFeeWAD;
    uint64 jtProtocolFeeWAD;
    uint64 jtYieldShareProtocolFeeWAD;
    NAV_UNIT effectiveNAVDustTolerance;
}

/**
 * @title MarketStateTransitionParams
 * @dev The inputs of the market state transition applied once per sync, after the PnL waterfall has settled the tranche NAVs
 * @custom:field postPnLWaterfallCheckpoint - The post-waterfall checkpoint: the synced raw and effective NAVs alongside the settled JT coverage impermanent loss
 * @custom:field stProtocolFeeAccrued - The protocol fee accrued on ST yield by the waterfall (zeroed in the marshaled state where the transition takes no fees)
 * @custom:field jtProtocolFeeAccrued - The protocol fee accrued on JT yield and the JT yield share by the waterfall (zeroed in the marshaled state where the transition takes no fees)
 * @custom:field betaWAD - JT's sensitivity to the same downside stress that affects ST, scaled to WAD precision
 * @custom:field minCoverageWAD - The coverage percentage that the senior tranche is expected to be protected by, scaled to WAD precision
 * @custom:field minLiquidityWAD - The percentage of the senior tranche NAV that must be in the liquidity tranche's market making inventory, scaled to WAD precision
 * @custom:field effectiveNAVDustTolerance - The effective NAV dust tolerance: the worst-case dust bounded by the sum of the raw NAV dust tolerances
 * @custom:field fixedTermDurationSeconds - The configured fixed-term duration for this market in seconds
 * @custom:field fixedTermEndTimestamp - The end timestamp of the currently ongoing fixed term (0 if the market is in a perpetual state)
 * @custom:field liquidationCoverageUtilizationWAD - The liquidation coverageUtilization threshold for this market, scaled to WAD precision
 * @custom:field currentTimestamp - The current block timestamp
 */
struct MarketStateTransitionParams {
    AccountingCheckpoint postPnLWaterfallCheckpoint;
    NAV_UNIT stProtocolFeeAccrued;
    NAV_UNIT jtProtocolFeeAccrued;
    uint256 betaWAD;
    uint256 minCoverageWAD;
    uint256 minLiquidityWAD;
    NAV_UNIT effectiveNAVDustTolerance;
    uint24 fixedTermDurationSeconds;
    uint32 fixedTermEndTimestamp;
    uint256 liquidationCoverageUtilizationWAD;
    uint256 currentTimestamp;
}

/**
 * @title Operation
 * @dev Defines the type of operation being executed by the user
 * @custom:type ST_DEPOSIT - A senior tranche deposit that increases ST's effective NAV
 * @custom:type ST_REDEEM - A senior tranche redemption that decreases ST's effective NAV
 * @custom:type JT_DEPOSIT - A junior tranche deposit that increases JT's effective NAV
 * @custom:type JT_REDEEM - A junior tranche redemption that decreases JT's effective NAV
 */
enum Operation {
    ST_DEPOSIT,
    ST_REDEEM,
    JT_DEPOSIT,
    JT_REDEEM
}

/**
 * @title TrancheType
 * @dev Defines the types of Royco tranches deployed per market.
 * @custom:type SENIOR - The identifier for the senior tranche (protected capital)
 * @custom:type JUNIOR - The identifier for the junior tranche (first-loss capital)
 * @custom:type LIQUIDITY - The identifier for the liquidity tranche (market-making capital; Royco Day markets only)
 * @dev Appended to preserve existing ordinals (SENIOR=0, JUNIOR=1) for storage/ABI compatibility with live markets.
 */
enum TrancheType {
    SENIOR,
    JUNIOR,
    LIQUIDITY
}

