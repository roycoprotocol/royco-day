// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayAccountant } from "../../src/accountant/RoycoDayAccountant.sol";
import { Math, NAV_UNIT } from "../../src/libraries/Units.sol";

/**
 * @title AccountantMaxViewsDriver
 * @notice Test driver over RoycoDayAccountant that seeds only the two NAV dust tolerances the max-capacity views
 *         read from ERC-7201 storage, so the maxSTDeposit, maxJTWithdrawal, and maxLTWithdrawal views can be
 *         exercised directly with a fully marshaled accounting-state struct and symbolic dust tolerances
 * @dev The three max views are already external on the accountant and take the whole SyncedAccountingState by
 *      value, reading every NAV, requirement, and gate input from that struct. The only storage they touch is
 *      the senior and junior dust tolerances, so this driver exposes a single narrow setter for those rather
 *      than the full checkpoint writer, keeping each symbolic query's storage surface minimal
 */
contract AccountantMaxViewsDriver is RoycoDayAccountant {
    constructor(address _kernel, bool _jtCoinvested) RoycoDayAccountant(_kernel, _jtCoinvested) { }

    /// @notice Seeds the senior and junior NAV dust tolerances (and their sum) that the max views read from storage
    function setDustTolerances(NAV_UNIT _stNAVDustTolerance, NAV_UNIT _jtNAVDustTolerance) external {
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        $.stNAVDustTolerance = _stNAVDustTolerance;
        $.jtNAVDustTolerance = _jtNAVDustTolerance;
        $.effectiveNAVDustTolerance = _stNAVDustTolerance + _jtNAVDustTolerance;
    }

    /**
     * @notice Exposes the same floor-rounded mulDiv the max views use internally, so a symbolic spec can execute
     *         the identical intermediate (rather than assuming a fresh floor bracket) and let the engine model
     *         the quotient's defining inequality directly
     */
    function mulDivFloor(uint256 _a, uint256 _b, uint256 _c) external pure returns (uint256) {
        return Math.mulDiv(_a, _b, _c, Math.Rounding.Floor);
    }

    /// @notice Exposes the same ceil-rounded mulDiv the liquidity and coverage requirements use internally
    function mulDivCeil(uint256 _a, uint256 _b, uint256 _c) external pure returns (uint256) {
        return Math.mulDiv(_a, _b, _c, Math.Rounding.Ceil);
    }
}
