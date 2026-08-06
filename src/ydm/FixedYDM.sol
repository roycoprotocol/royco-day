// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IYDM, MarketState, TrancheType } from "../interfaces/IYDM.sol";
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

    /// @dev A mapping from market accountants and the tranche types receiving the premium to the market's fixed yield shares (both fields pack into one storage slot)
    mapping(address accountant => mapping(TrancheType trancheType => FixedYieldShare share)) public accountantToFixedYieldShare;

    /**
     * @notice Emitted when the fixed YDM is initialized for a market
     * @param accountant The accountant for the market that the YDM was initialized for
     * @param trancheType The tranche type receiving the premium priced by this fixed share
     * @param fixedYieldShareWAD The fixed yield share paid at every utilization, scaled to WAD precision
     */
    event FixedYdmInitialized(address indexed accountant, TrancheType indexed trancheType, uint256 fixedYieldShareWAD);

    /**
     * @notice Emitted when the yield share is updated
     * @param accountant The accountant for the market that the yield share was updated for
     * @param trancheType The tranche type receiving the premium priced by this fixed share
     * @param yieldShareWAD The yield share output (returned to the accountant)
     */
    event YdmOutput(address indexed accountant, TrancheType indexed trancheType, uint256 yieldShareWAD);

    /**
     * @notice Initializes the YDM's fixed yield share for a particular Royco market and tranche type
     * @dev Must be called during the initialization of the accountant for the Royco market
     * @dev A zero share is a valid configuration: the market pays no premium, and the initialized flag keeps it distinguishable from an uninitialized market
     * @param _trancheType The tranche type receiving the premium priced by this fixed share, cannot be the senior tranche
     * @param _fixedYieldShareWAD The fixed yield share paid at every utilization, at most WAD, scaled to WAD precision
     */
    function initializeYDMForMarket(TrancheType _trancheType, uint64 _fixedYieldShareWAD) external {
        // The senior tranche pays the premiums and never receives one
        require(_trancheType != TrancheType.SENIOR, INVALID_YDM_INITIALIZATION());

        // The share can never exceed the whole of the paying tranche's yield
        require(_fixedYieldShareWAD <= WAD, INVALID_YDM_INITIALIZATION());

        // Initialize the YDM for the market and tranche type
        accountantToFixedYieldShare[msg.sender][_trancheType] = FixedYieldShare({ initialized: true, fixedYieldShareWAD: _fixedYieldShareWAD });

        emit FixedYdmInitialized(msg.sender, _trancheType, _fixedYieldShareWAD);
    }

    /// @inheritdoc IYDM
    /// @dev The fixed share is independent of the market state and the utilization, so both inputs are ignored
    function previewYieldShare(TrancheType _trancheType, MarketState, uint256) external view override(IYDM) returns (uint256 yieldShareWAD) {
        return _yieldShare(_trancheType);
    }

    /// @inheritdoc IYDM
    /// @dev The fixed share is independent of the market state and the utilization, so both inputs are ignored
    function yieldShare(TrancheType _trancheType, MarketState, uint256) external override(IYDM) returns (uint256 yieldShareWAD) {
        emit YdmOutput(msg.sender, _trancheType, (yieldShareWAD = _yieldShare(_trancheType)));
    }

    /// @dev View helper returning the caller's fixed yield share for the tranche type, failing shut for an uninitialized market
    function _yieldShare(TrancheType _trancheType) internal view returns (uint256 yieldShareWAD) {
        FixedYieldShare storage share = accountantToFixedYieldShare[msg.sender][_trancheType];
        require(share.initialized, UNINITIALIZED_YDM());
        return share.fixedYieldShareWAD;
    }
}
