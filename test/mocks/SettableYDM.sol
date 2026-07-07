// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IYDM } from "../../src/interfaces/IYDM.sol";
import { MarketState } from "../../src/libraries/Types.sol";

/// @title SettableYDM
/// @notice Minimal yield distribution model whose output is a single settable storage value on both entrypoints
contract SettableYDM is IYDM {
    /// @notice The yield share returned by both entrypoints, scaled to WAD precision
    uint256 public yieldShareWAD;

    /// @notice Sets the yield share that both entrypoints return
    function setYieldShare(uint256 _yieldShareWAD) external {
        yieldShareWAD = _yieldShareWAD;
    }

    /// @inheritdoc IYDM
    function previewYieldShare(MarketState, uint256) external view override(IYDM) returns (uint256) {
        return yieldShareWAD;
    }

    /// @inheritdoc IYDM
    function yieldShare(MarketState, uint256) external view override(IYDM) returns (uint256) {
        return yieldShareWAD;
    }
}
