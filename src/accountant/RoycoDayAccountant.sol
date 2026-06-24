// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoDawnKernel } from "../interfaces/IRoycoDawnKernel.sol";
import { IRoycoDayAccountant } from "../interfaces/IRoycoDayAccountant.sol";

import { IYDM } from "../interfaces/IYDM.sol";
import { MAX_PROTOCOL_FEE_WAD, MIN_COVERAGE_LOWER_BOUND_WAD, MIN_COVERAGE_UPPER_BOUND_WAD, WAD, ZERO_NAV_UNITS } from "../libraries/Constants.sol";
import { DawnAccountingLib } from "../libraries/DawnAccountingLib.sol";
import { DayUtilsLib } from "../libraries/DayUtilsLib.sol";
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
contract RoycoDayAccountant is IRoycoDayAccountant, RoycoDawnAccountant {
    /// @dev Storage slot for RoycoDayAccountantState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoDayAccountantState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_DAY_ACCOUNTANT_STORAGE_SLOT = 0x3eb9440b0208b8d20dc454b361ed9d3f272aa9a4fb2bcc89d823d3b8e5663200;

    // =============================
    // Construction and Initialization Functions
    // =============================

    /// @dev Constructs the accountant with the specified kernel
    /// @param _kernel The kernel that this accountant maintains mark-to-market NAV, JT coverage impermanent loss, and fee accounting for
    constructor(address _kernel) RoycoDawnAccountant(_kernel) { }

    /**
     * @notice Initializes the Royco accountant state
     * @param _params The initialization parameters for the Royco Day accountant
     * @param _initialAuthority The initial authority for the Royco accountant
     */
    function initialize(RoycoDayAccountantInitParams calldata _params, address _initialAuthority) external initializer {
        // Initialize the base state of the Day accountant
        __RoycoBase_init(_initialAuthority);
        // Initialize the Dawn accountant state
        __RoycoDawnAccountant_init_unchained(_params.dawnAccountantInitParams);
        // Initialize the Day accountant state
        __RoycoDayAccountant_init_unchained(_params);
    }

    /// @notice Initializes the Royco Day accountant state
    /// @param _params The initialization parameters for the Royco Day accountant
    function __RoycoDayAccountant_init_unchained(RoycoDayAccountantInitParams calldata _params) internal onlyInitializing {
        // Ensure that the protocol fee percentage is valid
        require(_params.ltProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD && _params.ltYieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        // Validate the market's initial liquidity configuration
        _validateLiquidityConfig(_params.minLiquidityWAD);
        // Initialize the LT YDM for this market
        _initializeYDM(_params.ltYDM, _params.ltYDMInitializationData);

        // Initialize the Day specific state of the accountant
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        $.ltProtocolFeeWAD = _params.ltProtocolFeeWAD;
        emit LiquidityTrancheProtocolFeeUpdated(_params.ltProtocolFeeWAD);
        $.ltYieldShareProtocolFeeWAD = _params.ltYieldShareProtocolFeeWAD;
        emit LiquidityTrancheYieldShareProtocolFeeUpdated(_params.ltYieldShareProtocolFeeWAD);
        $.minLiquidityWAD = _params.minLiquidityWAD;
        emit LiquidityUpdated(_params.minLiquidityWAD);
        $.ltYDM = _params.ltYDM;
        emit LiquidityTrancheYDMUpdated(_params.ltYDM);
        $.ltNAVDustTolerance = _params.ltNAVDustTolerance;
        emit LiquidityTrancheDustToleranceUpdated(_params.ltNAVDustTolerance);
    }

    // =============================
    // Liquidity Checking Functions
    // =============================

    /// @inheritdoc IRoycoDayAccountant
    function isLiquidityRequirementSatisfied() public view override(IRoycoDayAccountant) returns (bool) {
        // Get the storage pointer to the accountant state
        RoycoDayAccountantState storage $ = _getRoycoDayAccountantStorage();
        // Compute the liquidity utilization and return whether or the minimum liquidity demand is satisfied based on persisted NAVs
        uint256 liquidityUtilizationWAD =
            DayUtilsLib.computeLiquidityUtilization(_getRoycoDawnAccountantStorage().lastSTEffectiveNAV, $.minLiquidityWAD, $.lastLTRawNAV);
        return _isDemandSatisfied(liquidityUtilizationWAD);
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Validates the liquidity requirement parameters of the market
     * @param _minLiquidityWAD The liquidity ratio that the senior tranche is expected to be provided liquidity by, scaled to WAD precision
     */
    function _validateLiquidityConfig(uint64 _minLiquidityWAD) internal pure {
        require(
            // Ensure that the liquidity requirement is valid
            _minLiquidityWAD < WAD,
            INVALID_LIQUIDITY_CONFIG()
        );
    }

    // =============================
    // Storage Accessor Functions
    // =============================

    /**
     * @dev Returns a storage pointer to the Day accountant's specific state
     * @return $ Storage pointer to the Day accountant's specific state
     */
    function _getRoycoDayAccountantStorage() internal pure returns (RoycoDayAccountantState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_DAY_ACCOUNTANT_STORAGE_SLOT
        }
    }
}
