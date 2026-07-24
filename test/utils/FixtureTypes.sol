// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title FixtureTypes
 * @notice Shared configuration structs for the parameterized market fixture
 * @dev Declared file-level so TokenConfigs, MarketParams, and DayMarketTestBase share one definition
 */

/// @notice Full description of one token slot (the coinvested collateral asset or the quote asset)
/// @dev Behavior flags come from MockBehaviors, decimals is the share decimals when erc4626 is true
struct TokenConfig {
    uint8 decimals;
    uint256 behaviors;
    uint16 feeBps;
    bool erc4626;
    uint8 underlyingDecimals;
    uint256 initialRateWAD;
}

/**
 * @notice Full market parameterization, mirroring the accountant and kernel init params 1:1
 * @dev ydmKind values: 0 = MockYDM (pinned share), 1 = StaticCurveYDM, 2 = AdaptiveCurveYDM_V2
 */
struct MarketParamsConfig {
    // coverage / liquidity
    uint64 minCoverageWAD;
    uint256 coverageLiquidationUtilizationWAD;
    uint64 minLiquidityWAD;
    // premiums
    uint64 maxJTYieldShareWAD;
    uint64 maxLPTYieldShareWAD;
    // fees
    uint64 stProtocolFeeWAD;
    uint64 jtProtocolFeeWAD;
    uint64 jtYieldShareProtocolFeeWAD;
    uint64 lptYieldShareProtocolFeeWAD;
    // state machine / dust
    uint24 fixedTermDurationSeconds;
    uint256 dustTolerance;
    // kernel
    uint64 stSelfLiquidationBonusWAD;
    uint64 maxReinvestmentSlippageWAD;
    bool enforceWhitelistOnTransfer;
    // ydm wiring
    uint8 jtYdmKind;
    uint8 lptYdmKind;
    uint64[3] jtCurve;
    uint64[3] lptCurve;
    uint64 targetUtilizationWAD;
}

/// @notice One token shape for the market fixture (the lettered internal identifiers A..I built in TokenConfigs.sol)
struct FixtureCell {
    string name;
    TokenConfig collateralAsset;
    TokenConfig quoteAsset;
}
