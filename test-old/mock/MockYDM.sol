// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { MarketState } from "../../src/libraries/Types.sol";

/// @notice Mock YDM that returns a yield share > 100% (> WAD) to test capping logic
contract MockYDMOverWAD {
    uint256 public yieldShareToReturn;

    constructor(uint256 _yieldShare) {
        yieldShareToReturn = _yieldShare;
    }

    function setYieldShare(uint256 _yieldShare) external {
        yieldShareToReturn = _yieldShare;
    }

    function previewYieldShare(MarketState, uint256) external view returns (uint256) {
        return yieldShareToReturn;
    }

    function yieldShare(MarketState, uint256) external view returns (uint256) {
        return yieldShareToReturn;
    }
}

/// @notice Mock YDM that requires initialization and can fail
contract MockYDMWithInit {
    bool public initialized;

    function initialize(bool _shouldFail) external {
        if (_shouldFail) {
            revert("YDM_INIT_FAILED");
        }
        initialized = true;
    }

    function previewYieldShare(MarketState, uint256) external pure returns (uint256) {
        return 0.5e18;
    }

    function yieldShare(MarketState, uint256) external pure returns (uint256) {
        return 0.5e18;
    }
}
