// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { NAV_UNIT, TRANCHE_UNIT } from "./Units.sol";

/**
 * @title MarketState
 * @notice Defines the operational state of a Royco market
 * @custom:state PERPETUAL
 *      Normal operating state where market forces govern behavior, and the permanent state of a market configured with no fixed-term duration
 *      - The market is healthy (no losses over dust tolerance), severely undercollateralized (liquidation coverage utilization breached), or uncollateralized (no JT NAV remaining against a non-zero ST NAV)
 *      - All three tranches are liquid, subject to the coverage and liquidity requirements
 *      - While under/uncollateralized the LT shares ST's liquidity profile: the liquidity requirement is exempt
 *      - Premiums and protocol fees accrue on ST yield, and adaptive curve YDMs adapt to this market's coverage and liquidity utilization
 * @custom:state FIXED_TERM
 *      Temporary recovery state entered when JT covers an ST drawdown while coverage stays within the liquidation threshold
 *      - Entered when a non-dust JT coverage impermanent loss is first incurred
 *      - ST deposits and redemptions blocked: stops ST withdrawing coverage from existing JT on arbitrary volatility
 *      - JT deposits and redemptions blocked: stops new JT diluting existing JT on arbitrary volatility
 *      - LT redemptions blocked: keeps the LT market making the ST when secondary liquidity is most valuable
 *      - No liquidity premium is paid and no protocol fees are taken, since there is no yield to distribute during recovery
 *      - Adaptive curve YDMs do not adapt, since utilization moves on underlying PNL rather than market forces during recovery
 *      - Transitions back to PERPETUAL when the JT coverage impermanent loss clears or the term elapses, and is forced back on a liquidation breach or an uncollateralized market, clearing the JT coverage impermanent loss
 */
enum MarketState {
    PERPETUAL,
    FIXED_TERM
}

/**
 * @title AssetClaims
 * @dev A struct representing claims on senior tranche assets, junior tranche assets, liquidity tranche assets, and NAV
 * @custom:field stAssets - The claim on senior tranche assets denominated in ST's tranche units (only applicable for the ST and JT)
 * @custom:field jtAssets - The claim on junior tranche assets denominated in JT's tranche units (only applicable for the ST and JT)
 * @custom:field ltAssets - The claim on liquidity tranche assets denominated in LT's tranche units (only applicable for the LT)
 * @custom:field stShares - The claim on senior tranche shares (only applicable for the LT)
 * @custom:field nav - The net asset value of these claims in NAV units
 */
struct AssetClaims {
    // ST and JT claims
    TRANCHE_UNIT stAssets;
    TRANCHE_UNIT jtAssets;
    // LT claims
    TRANCHE_UNIT ltAssets;
    uint256 stShares;
    // Total net asset value of the claims
    NAV_UNIT nav;
}

/**
 * @title SyncedAccountingState
 * @dev Contains all current mark-to-market NAV accounting data for the market's tranches
 * @custom:field marketState - The current state of the Royco market (perpetual or fixed term)
 * @custom:field stRawNAV - The senior tranche's current raw NAV: the pure value of its invested assets
 * @custom:field jtRawNAV - The junior tranche's current raw NAV: the pure value of its invested assets
 * @custom:field ltRawNAV - The liquidity tranche's current raw NAV: the pure value of its invested assets
 * @custom:field stEffectiveNAV - Senior tranche effective NAV: includes applied coverage, its share of ST yield, and uncovered losses
 * @custom:field jtEffectiveNAV - Junior tranche effective NAV: includes provided coverage, JT yield, its share of ST yield, and JT losses
 * @custom:field jtCoverageImpermanentLoss - The impermanent loss that JT has suffered after providing coverage for ST losses
 *                                   This represents the claim on capital that the junior tranche has on future ST recoveries
 * @custom:field ltLiquidityPremium - The liquidity premium accrued to the liquidity tranche on this sync: LT's share of senior yield, minted as senior tranche shares to LT (coverage-neutral)
 * @custom:field stProtocolFee - Protocol fee taken on ST yield on this sync
 * @custom:field jtProtocolFee - Protocol fee taken on JT yield on this sync
 * @custom:field ltProtocolFee - Protocol fee taken on the liquidity premium (LT yield share) on this sync
 * @custom:field coverageUtilizationWAD - The current coverageUtilization of the market, scaled to WAD precision
 * @custom:field liquidityUtilizationWAD - The current liquidityUtilization of the market, scaled to WAD precision
 * @custom:field fixedTermEndTimestamp - The timestamp at which the fixed term ends. Set to 0 if the market is not in a fixed term state
 * @custom:field minCoverageWAD - The coverage percentage that the senior tranche is expected to be protected by, scaled to WAD precision
 * @custom:field jtCoinvested - Whether the junior tranche is co-invested in the same yield-bearing opportunity as senior (true means it shares senior's downside stress) or in the RFR (false)
 * @custom:field coverageLiquidationUtilizationWAD - The liquidation coverageUtilization threshold for this market, scaled to WAD precision
 * @custom:field minLiquidityWAD - The percentage of the senior tranche NAV that must be in the liquidity tranche's market making inventory, scaled to WAD precision
 */
struct SyncedAccountingState {
    // The market's current operating state (PERPETUAL or FIXED_TERM)
    MarketState marketState;
    // The market's marked-to-market NAVs, JT coverage impermanent loss, LT liquidity premium, and fees
    NAV_UNIT stRawNAV;
    NAV_UNIT jtRawNAV;
    NAV_UNIT ltRawNAV;
    NAV_UNIT stEffectiveNAV;
    NAV_UNIT jtEffectiveNAV;
    NAV_UNIT jtCoverageImpermanentLoss;
    NAV_UNIT ltLiquidityPremium;
    NAV_UNIT stProtocolFee;
    NAV_UNIT jtProtocolFee;
    NAV_UNIT ltProtocolFee;
    // The market's derived state metrics
    uint256 coverageUtilizationWAD;
    uint256 liquidityUtilizationWAD;
    uint32 fixedTermEndTimestamp;
    // The market's coverage configuration
    uint256 minCoverageWAD;
    bool jtCoinvested;
    uint256 coverageLiquidationUtilizationWAD;
    // The market's liquidity configuration
    uint256 minLiquidityWAD;
}

/**
 * @title Operation
 * @dev Defines the type of operation being executed by the user
 * @custom:type ST_DEPOSIT - A senior tranche deposit that increases ST's effective NAV
 * @custom:type ST_REDEEM - A senior tranche redemption that decreases ST's effective NAV
 * @custom:type JT_DEPOSIT - A junior tranche deposit that increases JT's effective NAV
 * @custom:type JT_REDEEM - A junior tranche redemption that decreases JT's effective NAV
 * @custom:type LT_DEPOSIT - A liquidity tranche deposit that increases LT's effective NAV
 * @custom:type LT_REDEEM - A liquidity tranche redemption that decreases LT's effective NAV
 */
enum Operation {
    ST_DEPOSIT,
    ST_REDEEM,
    JT_DEPOSIT,
    JT_REDEEM,
    LT_DEPOSIT,
    LT_REDEEM
}

/**
 * @title TrancheType
 * @dev Defines the types of Royco tranches deployed per market.
 * @custom:type SENIOR - The identifier for the senior tranche (protected capital)
 * @custom:type JUNIOR - The identifier for the junior tranche (first-loss capital)
 * @custom:type LIQUIDITY - The identifier for the liquidity tranche (market-making capital)
 */
enum TrancheType {
    SENIOR,
    JUNIOR,
    LIQUIDITY
}

