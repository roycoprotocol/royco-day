// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IYDM } from "../../src/interfaces/IYDM.sol";
import { MarketState } from "../../src/libraries/Types.sol";

/// @notice Recording YDM mock with independently settable mutating and preview outputs, mutating-call argument recording, and per-entrypoint revert modes
/// @dev The preview path is a staticcall from the accountant so preview arguments are asserted via vm.expectCall in tests, not recorded here
contract MockRecordingYDM is IYDM {
    error YDM_REVERTED();
    error YDM_INIT_REVERTED();

    uint256 public yieldShareReturn;
    uint256 public previewYieldShareReturn;
    bool public revertOnYieldShare;
    bool public revertOnPreviewYieldShare;
    bool public revertOnInitialize;

    uint256 public yieldShareCallCount;
    MarketState public lastYieldShareMarketState;
    uint256 public lastYieldShareUtilizationWAD;

    uint256 public initializeCallCount;
    bytes public lastInitializePayload;

    function setYieldShareReturn(uint256 _v) external {
        yieldShareReturn = _v;
    }

    function setPreviewYieldShareReturn(uint256 _v) external {
        previewYieldShareReturn = _v;
    }

    /// @dev Convenience setter for both the mutating and preview outputs
    function setRates(uint256 _v) external {
        yieldShareReturn = _v;
        previewYieldShareReturn = _v;
    }

    function setRevertOnYieldShare(bool _v) external {
        revertOnYieldShare = _v;
    }

    function setRevertOnPreviewYieldShare(bool _v) external {
        revertOnPreviewYieldShare = _v;
    }

    function setRevertOnInitialize(bool _v) external {
        revertOnInitialize = _v;
    }

    /// @dev Initialization entrypoint targeted by the accountant's raw-call YDM initialization
    function initializeModel(bytes calldata _payload) external {
        if (revertOnInitialize) revert YDM_INIT_REVERTED();
        initializeCallCount++;
        lastInitializePayload = _payload;
    }

    /// @inheritdoc IYDM
    function yieldShare(MarketState _marketState, uint256 _utilizationWAD) external override(IYDM) returns (uint256) {
        if (revertOnYieldShare) revert YDM_REVERTED();
        yieldShareCallCount++;
        lastYieldShareMarketState = _marketState;
        lastYieldShareUtilizationWAD = _utilizationWAD;
        return yieldShareReturn;
    }

    /// @inheritdoc IYDM
    function previewYieldShare(MarketState, uint256) external view override(IYDM) returns (uint256) {
        if (revertOnPreviewYieldShare) revert YDM_REVERTED();
        return previewYieldShareReturn;
    }
}
