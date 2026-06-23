// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoDawnKernel } from "../interfaces/IRoycoDawnKernel.sol";
import { IYDM } from "../interfaces/IYDM.sol";
import { MAX_COVERAGE_WAD, MAX_PROTOCOL_FEE_WAD, MIN_COVERAGE_WAD, WAD, ZERO_NAV_UNITS } from "../libraries/Constants.sol";
import { DawnAccountingLib } from "../libraries/DawnAccountingLib.sol";
import { DawnUtilsLib, Math } from "../libraries/DawnUtilsLib.sol";
import {
    AccountingCheckpoint,
    MarketState,
    MarketStateTransitionParams,
    NAV_UNIT,
    Operation,
    PnLWaterfallParams,
    SyncedAccountingState
} from "../libraries/Types.sol";
import { UnitsMathLib, toNAVUnits } from "../libraries/Units.sol";
import { RoycoDawnAccountant } from "./RoycoDawnAccountant.sol";

/**
 * @title RoycoDayAccountant
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Performs and tracks the core accounting operations for a Royco market
 * @notice Responsible for marking tranche NAVs to market, tracking the JT coverage impermanent loss, distributing yield via the YDM, and computing protocol fees
 * @notice Responsible for tracking the accounting, coverage, and liquidity state of the Royco market
 */
contract RoycoDayAccountant is RoycoDawnAccountant {
    // =============================
    // Construction and Initialization Functions
    // =============================

    /// @dev Constructs the accountant with the specified kernel
    /// @param _kernel The kernel that this accountant maintains mark-to-market NAV, JT coverage impermanent loss, and fee accounting for
    constructor(address _kernel) RoycoDawnAccountant(_kernel) { }

    /**
     * @notice Initializes the Royco accountant state
     * @param _params The initialization parameters for the Royco accountant
     * @param _initialAuthority The initial authority for the Royco accountant
     */
    function initialize(RoycoDawnAccountantInitParams calldata _params, address _initialAuthority) external override(RoycoDawnAccountant) initializer {
        __RoycoDawnAccountant_init(_params, _initialAuthority);
    }
}
