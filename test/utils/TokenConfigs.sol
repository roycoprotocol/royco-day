// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { WAD } from "../../src/libraries/Constants.sol";
import { MockBehaviors } from "../mocks/MockBehaviors.sol";
import { FixtureCell, TokenConfig } from "./FixtureTypes.sol";

/**
 * @title TokenConfigs
 * @notice Canonical token shapes for the parameterized market fixture, keyed by the internal identifiers A..I
 *         (the "cell" letters survive only in this file, as internal identifiers)
 * @dev Hard rule, no test instantiates token mocks directly, tokens come exclusively from these builders
 * @dev Every shipped ST/JT quoter is in the IdenticalAssets family and the kernel constructor requires ST_ASSET == JT_ASSET,
 *      so every shape uses ONE MockERC4626C instance for both ST and JT and the stAsset/jtAsset configs are always identical
 * @dev Cell D contributes the 8-decimal-shares axis
 */

/// @dev Builds a plain (non-4626) token config with no behaviors
function _plainToken(uint8 _decimals) pure returns (TokenConfig memory) {
    return TokenConfig({ decimals: _decimals, behaviors: MockBehaviors.BEHAVIOR_NONE, feeBps: 0, erc4626: false, underlyingDecimals: 0, initialRateWAD: 0 });
}

/// @dev Builds a 4626 vault-share token config at a 1.0 WAD initial rate with no underlying behaviors
function _vaultToken(uint8 _shareDecimals, uint8 _underlyingDecimals) pure returns (TokenConfig memory) {
    return TokenConfig({
        decimals: _shareDecimals, behaviors: MockBehaviors.BEHAVIOR_NONE, feeBps: 0, erc4626: true, underlyingDecimals: _underlyingDecimals, initialRateWAD: WAD
    });
}

/// @notice Cell A, the baseline cell, 4626(18,18) ST/JT shares against a 6-decimal quote stable
function cellA() pure returns (FixtureCell memory) {
    TokenConfig memory vault = _vaultToken(18, 18);
    return FixtureCell({ name: "A", stAsset: vault, jtAsset: vault, quoteAsset: _plainToken(6) });
}

/// @notice Cell B, low-decimal shares, 4626(6,6) ST/JT shares against an 18-decimal quote stable
function cellB() pure returns (FixtureCell memory) {
    TokenConfig memory vault = _vaultToken(6, 6);
    return FixtureCell({ name: "B", stAsset: vault, jtAsset: vault, quoteAsset: _plainToken(18) });
}

/// @notice Cell C, decimal-skewed vault, 4626(18,6) shares (18-dec shares over a 6-dec underlying) against a 6-decimal quote
function cellC() pure returns (FixtureCell memory) {
    TokenConfig memory vault = _vaultToken(18, 6);
    return FixtureCell({ name: "C", stAsset: vault, jtAsset: vault, quoteAsset: _plainToken(6) });
}

/**
 * @notice Cell D, 8-decimal shares, 4626(8,8) ST/JT shares against a 6-decimal quote
 * @dev The kernel constructor requires identical ST/JT assets and the shipped quoter family only supports identical assets
 */
function cellD() pure returns (FixtureCell memory) {
    TokenConfig memory vault = _vaultToken(8, 8);
    return FixtureCell({ name: "D", stAsset: vault, jtAsset: vault, quoteAsset: _plainToken(6) });
}

/// @notice Cell E, hostile-transfer semantics, REVERT_ON_ZERO on the ST/JT vault underlying and BLOCKLIST on the quote
function cellE() pure returns (FixtureCell memory) {
    TokenConfig memory vault = _vaultToken(18, 18);
    vault.behaviors = MockBehaviors.BEHAVIOR_REVERT_ON_ZERO;
    TokenConfig memory quote = _plainToken(6);
    quote.behaviors = MockBehaviors.BEHAVIOR_BLOCKLIST;
    return FixtureCell({ name: "E", stAsset: vault, jtAsset: vault, quoteAsset: quote });
}

/// @notice Cell F, USDT-shaped quote, NO_RETURN_VALUE (empty returndata) on the quote stable's transfer paths
function cellF() pure returns (FixtureCell memory) {
    TokenConfig memory vault = _vaultToken(18, 18);
    TokenConfig memory quote = _plainToken(6);
    quote.behaviors = MockBehaviors.BEHAVIOR_NO_RETURN_VALUE;
    return FixtureCell({ name: "F", stAsset: vault, jtAsset: vault, quoteAsset: quote });
}

/// @notice Cell G, fee-on-transfer underlying at 10bps, an EXPECTED-FAILURE cell probing balance-vs-accounting drift
function cellG() pure returns (FixtureCell memory) {
    TokenConfig memory vault = _vaultToken(18, 18);
    vault.behaviors = MockBehaviors.BEHAVIOR_FEE_ON_TRANSFER;
    vault.feeBps = 10;
    return FixtureCell({ name: "G", stAsset: vault, jtAsset: vault, quoteAsset: _plainToken(6) });
}

/// @notice Cell H, rebasing underlying, balance reads scale by a settable index on the ST/JT vault underlying
function cellH() pure returns (FixtureCell memory) {
    TokenConfig memory vault = _vaultToken(18, 18);
    vault.behaviors = MockBehaviors.BEHAVIOR_REBASING;
    return FixtureCell({ name: "H", stAsset: vault, jtAsset: vault, quoteAsset: _plainToken(6) });
}

/// @notice Cell I, 8-decimal quote stable against the baseline 4626(18,18) ST/JT shares
function cellI() pure returns (FixtureCell memory) {
    TokenConfig memory vault = _vaultToken(18, 18);
    return FixtureCell({ name: "I", stAsset: vault, jtAsset: vault, quoteAsset: _plainToken(8) });
}
