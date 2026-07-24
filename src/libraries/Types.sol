// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { NAV_UNIT, TRANCHE_UNIT } from "./Units.sol";

/**
 * @title MarketState
 * @notice Defines the operational state of a Royco market
 * @custom:state PERPETUAL
 *      Normal operating state where market forces govern behavior, and the permanent state of a market configured with no fixed-term duration
 *      - The market is healthy (no losses over dust tolerance), severely undercollateralized (liquidation coverage utilization breached), or uncollateralized (no JT NAV remaining against a non-zero ST NAV)
 *      - All three tranches are liquid, subject to the coverage and liquidity requirements at all times, including while under or uncollateralized
 *      - Premiums and protocol fees accrue on ST yield, and adaptive curve YDMs adapt to this market's coverage and liquidity utilization
 * @custom:state FIXED_TERM
 *      Temporary recovery state entered when JT covers an ST drawdown while coverage stays within the liquidation threshold
 *      - Entered when a non-dust JT impermanent loss is first incurred
 *      - ST deposits and redemptions blocked: stops ST withdrawing coverage from existing JT on arbitrary volatility
 *      - JT deposits and redemptions blocked: stops new JT diluting existing JT on arbitrary volatility
 *      - LPT redemptions blocked: keeps the LPT market making the ST when secondary liquidity is most valuable
 *      - No liquidity premium is paid and no protocol fees are taken, since there is no yield to distribute during recovery
 *      - Adaptive curve YDMs do not adapt, since utilization moves on underlying PNL rather than market forces during recovery
 *      - Transitions back to PERPETUAL when the JT impermanent loss clears or the term elapses, and is forced back on a liquidation breach or an uncollateralized market, clearing the JT impermanent loss
 */
enum MarketState {
    PERPETUAL,
    FIXED_TERM
}

/**
 * @title AssetClaims
 * @dev A struct representing claims on collateral assets, liquidity provider tranche assets, senior tranche shares, and NAV
 * @custom:field collateralAssets - The claim on the coinvested collateral assets denominated in tranche units (only applicable for the ST and JT)
 * @custom:field lptAssets - The claim on liquidity provider tranche assets denominated in LPT's tranche units (only applicable for the LPT)
 * @custom:field stShares - The claim on senior tranche shares (only applicable for the LPT)
 * @custom:field nav - The net asset value of these claims in NAV units
 */
struct AssetClaims {
    // ST and JT claims
    TRANCHE_UNIT collateralAssets;
    // LPT claims
    TRANCHE_UNIT lptAssets;
    uint256 stShares;
    // Total net asset value of the claims
    NAV_UNIT nav;
}

/**
 * @title SyncedAccountingState
 * @dev Contains all current mark-to-market NAV accounting data for the market's tranches
 * @custom:field marketState - The current state of the Royco market (perpetual or fixed term)
 * @custom:field collateralNAV - The pure value of the coinvested collateral backing the senior and junior tranches, always equal to (stEffectiveNAV + jtEffectiveNAV)
 * @custom:field lptRawNAV - The liquidity provider tranche's current raw NAV: the mark-to-market value of its market making inventory
 * @custom:field stEffectiveNAV - Senior tranche effective NAV: its claim on the collateral, includes applied coverage, its share of ST yield, and uncovered losses
 * @custom:field jtEffectiveNAV - Junior tranche effective NAV: its claim on the collateral, includes provided coverage, JT yield, its share of ST yield, and JT losses
 * @custom:field jtImpermanentLoss - The junior tranche's impermanent loss: JT's recoverable drawdown, deepened by JT losses and provided coverage, repaid by JT's first claim on appreciation/recovery
 * @custom:field lptLiquidityPremium - The liquidity premium accrued to the liquidity provider tranche on this sync: LPT's share of senior yield, minted as senior tranche shares to LPT (coverage-neutral)
 * @custom:field stProtocolFee - Protocol fee taken on ST yield on this sync
 * @custom:field jtProtocolFee - Protocol fee taken on JT yield on this sync
 * @custom:field lptProtocolFee - Protocol fee taken on the liquidity premium (LPT yield share) on this sync
 * @custom:field coverageUtilizationWAD - The current coverageUtilization of the market, scaled to WAD precision
 * @custom:field liquidityUtilizationWAD - The current liquidityUtilization of the market, scaled to WAD precision
 * @custom:field fixedTermEndTimestamp - The timestamp at which the fixed term ends, set to 0 if the market is not in a fixed term state
 * @custom:field minCoverageWAD - The coverage percentage that the senior tranche is expected to be protected by, scaled to WAD precision
 * @custom:field coverageLiquidationUtilizationWAD - The liquidation coverageUtilization threshold for this market, scaled to WAD precision
 * @custom:field minLiquidityWAD - The percentage of the senior tranche NAV that must be in the liquidity provider tranche's market making inventory, scaled to WAD precision
 */
struct SyncedAccountingState {
    // The market's current operating state (PERPETUAL or FIXED_TERM)
    MarketState marketState;
    // The market's marked-to-market NAVs, JT impermanent loss, LPT liquidity premium, and fees
    NAV_UNIT collateralNAV;
    NAV_UNIT lptRawNAV;
    NAV_UNIT stEffectiveNAV;
    NAV_UNIT jtEffectiveNAV;
    NAV_UNIT jtImpermanentLoss;
    NAV_UNIT lptLiquidityPremium;
    NAV_UNIT stProtocolFee;
    NAV_UNIT jtProtocolFee;
    NAV_UNIT lptProtocolFee;
    // The market's derived state metrics
    uint256 coverageUtilizationWAD;
    uint256 liquidityUtilizationWAD;
    uint32 fixedTermEndTimestamp;
    // The market's coverage configuration
    uint256 minCoverageWAD;
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
 * @custom:type LPT_DEPOSIT - An in-kind liquidity provider tranche deposit that only adds market-making inventory
 * @custom:type LPT_REDEEM - An in-kind liquidity provider tranche redemption that only removes market-making inventory and idle premium shares
 * @custom:type LPT_MULTI_ASSET_DEPOSIT - A multi-asset liquidity provider tranche deposit that can also mint and deploy senior exposure via its senior leg
 * @custom:type LPT_MULTI_ASSET_REDEEM - A multi-asset liquidity provider tranche redemption that also unwinds senior exposure and can pay a self-liquidation bonus
 */
enum Operation {
    ST_DEPOSIT,
    ST_REDEEM,
    JT_DEPOSIT,
    JT_REDEEM,
    LPT_DEPOSIT,
    LPT_REDEEM,
    LPT_MULTI_ASSET_DEPOSIT,
    LPT_MULTI_ASSET_REDEEM
}

/**
 * @title TrancheType
 * @dev Defines the types of Royco tranches deployed per market
 * @custom:type SENIOR - The identifier for the senior tranche (protected capital)
 * @custom:type JUNIOR - The identifier for the junior tranche (first-loss capital)
 * @custom:type LIQUIDITY_PROVIDER - The identifier for the liquidity provider tranche (senior's market-making capital)
 */
enum TrancheType {
    SENIOR,
    JUNIOR,
    LIQUIDITY_PROVIDER
}

