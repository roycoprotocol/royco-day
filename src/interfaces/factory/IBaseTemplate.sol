// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { NAV_UNIT } from "../../libraries/Units.sol";
import { IRoycoFactory } from "./IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "./IRoycoProtocolTemplate.sol";

/**
 * @title IBaseTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Common surface shared by every concrete Royco deployment template, on top of `IRoycoProtocolTemplate`
 */
interface IBaseTemplate is IRoycoProtocolTemplate {
    /**
     * @notice A tranche's deployer-supplied initialization params
     * @custom:field name - The tranche share token's name
     * @custom:field symbol - The tranche share token's symbol
     */
    struct TrancheDeploymentParams {
        string name;
        string symbol;
    }

    /**
     * @notice The accountant's deployer-supplied initialization params
     * @custom:field fixedTermGracePeriodSeconds - The seconds after deployment during which the market cannot enter a fixed term no matter what, so a young market is never locked by an early junior impermanent loss
     * @custom:field minCoverageWAD - The coverage ratio that the senior tranche is expected to be protected by, scaled to WAD precision
     * @custom:field coverageLiquidationUtilizationWAD - The liquidation coverageUtilization threshold for this market, scaled to WAD precision
     * @custom:field minLiquidityWAD - The percentage of the senior tranche NAV that must be in the liquidity provider tranche's market making inventory, scaled to WAD precision
     * @custom:field jtYDMInitializationData - The data used to initialize this market's JT YDM instance
     * @custom:field lptYDMInitializationData - The data used to initialize this market's LPT YDM instance
     * @custom:field maxJTYieldShareWAD - The maximum JT yield share (risk premium) as a percentage of senior appreciation, scaled to WAD precision
     * @custom:field maxLPTYieldShareWAD - The maximum LPT yield share (liquidity premium) as a percentage of senior appreciation, scaled to WAD precision
     * @custom:field fixedTermDurationSeconds - The duration of a fixed term for this market in seconds
     * @custom:field dustTolerance - The worst case dust tolerance for collateralNAV from underlying NAV quoting/rounding
     */
    struct AccountantDeploymentParams {
        // Deployment configuration
        uint24 fixedTermGracePeriodSeconds;
        // Coverage configuration
        uint64 minCoverageWAD;
        uint256 coverageLiquidationUtilizationWAD;
        // Liquidity configuration
        uint64 minLiquidityWAD;
        // Yield distribution model initialization
        bytes jtYDMInitializationData;
        bytes lptYDMInitializationData;
        // Maximum yield shares (premiums)
        uint64 maxJTYieldShareWAD;
        uint64 maxLPTYieldShareWAD;
        // Fixed term duration
        uint24 fixedTermDurationSeconds;
        // Dust tolerance
        NAV_UNIT dustTolerance;
    }

    /// @notice Thrown when a factory-only function is called by another address
    error ONLY_ROYCO_FACTORY();

    /// @notice Thrown when the template is constructed with the zero address as its factory
    error ROYCO_FACTORY_CANNOT_BE_ZERO_ADDRESS();

    /// @notice Thrown when two index-aligned arrays have mismatched lengths
    error LENGTH_MISMATCH();

    /// @notice The factory this template is bound to
    function ROYCO_FACTORY() external view returns (IRoycoFactory);
}
