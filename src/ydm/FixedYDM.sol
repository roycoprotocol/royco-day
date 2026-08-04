// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IYDM, MarketState } from "../interfaces/IYDM.sol";
import { WAD } from "../libraries/Constants.sol";

/**
 * @title FixedYDM
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Royco's fixed yield distribution model (YDM): a constant yield share independent of utilization
 * @dev A general-purpose model for paying a tranche's yield as a flat premium to a capital pool, including a fixed zero
 * @dev The model has no concept of a target utilization and ignores the utilization input completely, so it implements
 *      IYDM directly rather than extending BaseYDM
 * @dev The explicit initialized flag disambiguates a configured zero share from an uninitialized market, so queries
 *      against an uninitialized market fail shut while the zero share stays expressible
 */
contract FixedYDM is IYDM {
    /**
     * @notice Represents the state of a market's YDM
     * @custom:field initialized - Whether the market's fixed share has been initialized, the explicit marker that keeps a configured zero share distinguishable from an uninitialized market
     * @custom:field fixedYieldShareWAD - The fixed yield share paid at every utilization, scaled to WAD precision
     */
    struct FixedYieldShare {
        bool initialized;
        uint64 fixedYieldShareWAD;
    }

    /// @dev A mapping from market accountants to its market's fixed yield share (both fields pack into one storage slot)
    mapping(address accountant => FixedYieldShare share) public accountantToFixedYieldShare;

    /**
     * @notice Emitted when the fixed YDM is initialized for a market
     * @param accountant The accountant for the market that the YDM was initialized for
     * @param fixedYieldShareWAD The fixed yield share paid at every utilization, scaled to WAD precision
     */
    event FixedYdmInitialized(address indexed accountant, uint256 fixedYieldShareWAD);

    /**
     * @notice Emitted when the yield share is updated
     * @param accountant The accountant for the market that the yield share was updated for
     * @param yieldShareWAD The yield share output (returned to the accountant)
     */
    event YdmOutput(address indexed accountant, uint256 yieldShareWAD);

    /**
     * @notice Initializes the YDM's fixed yield share for a particular Royco market
     * @dev Must be called during the initialization of the accountant for the Royco market
     * @dev A zero share is a valid configuration: the market pays no premium, and the initialized flag keeps it distinguishable from an uninitialized market
     * @param _fixedYieldShareWAD The fixed yield share paid at every utilization, at most WAD, scaled to WAD precision
     */
    function initializeYDMForMarket(uint64 _fixedYieldShareWAD) external {
        // The share can never exceed the whole of the paying tranche's yield
        require(_fixedYieldShareWAD <= WAD, INVALID_YDM_INITIALIZATION());

        // Initialize the YDM for the market
        accountantToFixedYieldShare[msg.sender] = FixedYieldShare({ initialized: true, fixedYieldShareWAD: _fixedYieldShareWAD });

        emit FixedYdmInitialized(msg.sender, _fixedYieldShareWAD);
    }

    /// @inheritdoc IYDM
    /// @dev The fixed share is independent of the market state and the utilization, so both inputs are ignored
    function previewYieldShare(MarketState, uint256) external view override(IYDM) returns (uint256 yieldShareWAD) {
        return _yieldShare();
    }

    /// @inheritdoc IYDM
    /// @dev The fixed share is independent of the market state and the utilization, so both inputs are ignored
    function yieldShare(MarketState, uint256) external override(IYDM) returns (uint256 yieldShareWAD) {
        emit YdmOutput(msg.sender, (yieldShareWAD = _yieldShare()));
    }

    /// @dev View helper returning the caller's fixed yield share, failing shut for an uninitialized market
    function _yieldShare() internal view returns (uint256 yieldShareWAD) {
        FixedYieldShare storage share = accountantToFixedYieldShare[msg.sender];
        require(share.initialized, UNINITIALIZED_YDM());
        return share.fixedYieldShareWAD;
    }
}
