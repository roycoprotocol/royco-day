// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";

/**
 * @title TrancheFixture (SCAFFOLD — Phase A implements this; see docs/testing-strategy.md §2.2)
 * @notice The single parameterized fixture every test layer inherits. Hardcoded 18-decimal mocks are
 *         prohibited: tokens come exclusively from TokenConfig cells (docs/testing-strategy.md §2.3).
 */

/// @dev Token behavior flags, OR-able. NONE == fully standard ERC20.
uint256 constant BEHAVIOR_NONE = 0;
uint256 constant BEHAVIOR_FEE_ON_TRANSFER = 1 << 0; // feeBps applies on every transfer
uint256 constant BEHAVIOR_REBASING = 1 << 1; // balances scale by a settable index
uint256 constant BEHAVIOR_NO_RETURN_VALUE = 1 << 2; // USDT-style empty returndata
uint256 constant BEHAVIOR_REVERT_ON_ZERO = 1 << 3; // reverts on zero-amount transfer/approve
uint256 constant BEHAVIOR_BLOCKLIST = 1 << 4; // per-address deny list
uint256 constant BEHAVIOR_PAUSABLE = 1 << 5;
uint256 constant BEHAVIOR_HOOK_ON_TRANSFER = 1 << 6; // calls a hook target on transfer (reentrancy probe)

/// @notice Full description of one token slot (ST asset, JT asset, or quote asset).
struct TokenConfig {
    uint8 decimals; // token decimals (share decimals when erc4626 == true)
    uint256 behaviors; // BEHAVIOR_* bitmap
    uint16 feeBps; // only read when FEE_ON_TRANSFER set
    bool erc4626; // true => MockERC4626C wrapping an underlying MockERC20C
    uint8 underlyingDecimals; // only read when erc4626 == true
    uint256 initialRateWAD; // erc4626 convertToAssets rate seed, WAD-scaled
}

/// @notice Full market parameterization; mirrors accountant/kernel init params 1:1.
struct MarketParamsConfig {
    // coverage / liquidity
    uint64 minCoverageWAD; // < WAD (RoycoDayAccountant.sol:85)
    uint256 coverageLiquidationUtilizationWAD; // > WAD
    uint64 minLiquidityWAD; // < WAD
    bool jtCoinvested;
    // premiums
    uint64 maxJTYieldShareWAD; // maxJT + maxLT <= WAD (RoycoDayAccountant.sol:985-988)
    uint64 maxLTYieldShareWAD;
    // fees (each <= MAX_PROTOCOL_FEE_WAD)
    uint64 stProtocolFeeWAD;
    uint64 jtProtocolFeeWAD;
    uint64 jtYieldShareProtocolFeeWAD;
    uint64 ltYieldShareProtocolFeeWAD;
    // state machine / dust
    uint24 fixedTermDurationSeconds;
    uint256 stNAVDustTolerance;
    uint256 jtNAVDustTolerance;
    // kernel
    uint64 stSelfLiquidationBonusWAD;
    uint64 maxReinvestmentSlippageWAD; // < WAD
    bool enforceWhitelistOnTransfer;
    // ydm wiring: 0 = MockYDM (pinned share), 1 = StaticCurveYDM, 2 = AdaptiveCurveYDM_V2
    uint8 jtYdmKind;
    uint8 ltYdmKind;
    uint64[3] jtCurve; // (yAtZero, yAtTarget, yAtFull) WAD
    uint64[3] ltCurve;
    uint64 targetUtilizationWAD;
}

/// @notice One cell of the token matrix (docs/testing-strategy.md §2.3, cells A..I).
struct FixtureCell {
    string name; // "A".."I" — used in test labels and CI matrix selection
    TokenConfig stAsset;
    TokenConfig jtAsset;
    TokenConfig quoteAsset;
}

abstract contract TrancheFixture is Test {
    FixtureCell internal cell;
    MarketParamsConfig internal params;

    // Deployed market handles (populated by _deployMarket; concrete types wired in Phase A).
    address internal seniorTranche;
    address internal juniorTranche;
    address internal liquidityTranche;
    address internal kernel;
    address internal accountant;
    address internal ltVenue; // MockBalancerVault or real vault on fork

    /// @dev Deploys the full market for (cell, params) through the factory path where possible,
    ///      so wiring/roles match production. Implemented in Phase A.
    function _deployMarket(FixtureCell memory _cell, MarketParamsConfig memory _params) internal virtual;

    /// @dev PnL injection mutates the mock rate/oracle — never `deal` — so PnL flows through the
    ///      same quoter path production uses (docs/testing-strategy.md §2.2).
    function applySTPnL(int256 _bps) internal virtual;
    function applyJTPnL(int256 _bps) internal virtual;
    function applyLTPnL(int256 _bps) internal virtual;

    /// @dev Venue control for the reinvestment slippage gate (handler mitigation #4, §3).
    function setVenueSlippageMode(bool _reinvestmentsFail) internal virtual;

    /// @dev Oracle failure-mode control (STALE / NEGATIVE / SEQUENCER_DOWN / ...).
    function setOracleMode(uint8 _mode) internal virtual;
}
