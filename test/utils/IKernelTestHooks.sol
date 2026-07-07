// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { NAV_UNIT, TRANCHE_UNIT } from "../../src/libraries/Units.sol";

/// @title IKernelTestHooks
/// @notice The per-kernel test seam. A concrete kernel test implements these hooks so the abstract kernel
///         suites can drive yield/loss, fund users, and read tolerances without knowing the kernel's
///         underlying valuation mechanism (ERC4626 share price, Chainlink oracle, Balancer E-CLP, etc.).
/// @dev Design notes vs the original interface:
///      - `stAsset`/`jtAsset`/`quoteAsset` are independent, so a concrete kernel can exercise st-asset != jt-asset
///        (different decimals and/or price). Suites must NOT assume `stAsset == jtAsset`.
///      - `quoteAsset` + `hasLiquidityTranche` describe the LT leg; kernels without an LT set them to
///        `address(0)` / `false` and the LT suite skips.
///      - `simulate*Yield`/`simulate*Loss` must actually move the tranche's RAW nav in the stated direction and
///        magnitude; the suites assert on the realized post-sync numbers, so an approximate move is not enough.
interface IKernelTestHooks {
    /// @notice Static configuration describing the market a concrete kernel test stands up.
    /// @custom:field forkBlock            Block to fork at (0 for a non-fork, in-memory market).
    /// @custom:field forkRpcUrlEnvVar     Env var holding the RPC URL (empty for a non-fork market).
    /// @custom:field stAsset              Senior tranche underlying asset.
    /// @custom:field jtAsset              Junior tranche underlying asset (MAY differ from `stAsset`).
    /// @custom:field quoteAsset           LT pool quote asset (address(0) when `hasLiquidityTranche` is false).
    /// @custom:field hasLiquidityTranche  Whether this market wires an LT (gates the LT abstract suite).
    /// @custom:field initialFunding       Initial per-user funding amount, in each asset's own decimals.
    struct TestConfig {
        uint256 forkBlock;
        string forkRpcUrlEnvVar;
        address stAsset;
        address jtAsset;
        address quoteAsset;
        bool hasLiquidityTranche;
        uint256 initialFunding;
    }

    /// @notice Returns the static test configuration for this concrete kernel.
    function getTestConfig() external view returns (TestConfig memory);

    /// @notice Simulates positive senior NAV change of `_percentageWAD` (e.g. 0.05e18 = +5% of ST raw NAV).
    function simulateSTYield(uint256 _percentageWAD) external;

    /// @notice Simulates positive junior NAV change of `_percentageWAD`.
    function simulateJTYield(uint256 _percentageWAD) external;

    /// @notice Simulates negative senior NAV change of `_percentageWAD` (e.g. 0.05e18 = -5% of ST raw NAV).
    function simulateSTLoss(uint256 _percentageWAD) external;

    /// @notice Simulates negative junior NAV change of `_percentageWAD`.
    function simulateJTLoss(uint256 _percentageWAD) external;

    /// @notice Deals `_amount` of the senior asset (in its own decimals) to `_to`.
    function dealSTAsset(address _to, uint256 _amount) external;

    /// @notice Deals `_amount` of the junior asset (in its own decimals) to `_to`.
    function dealJTAsset(address _to, uint256 _amount) external;

    /// @notice Deals `_amount` of the LT pool quote asset to `_to`. Reverts / no-op for markets without an LT.
    function dealQuoteAsset(address _to, uint256 _amount) external;

    /// @notice Maximum absolute delta tolerated on `TRANCHE_UNIT` comparisons for this kernel's rounding.
    function maxTrancheUnitDelta() external view returns (TRANCHE_UNIT);

    /// @notice Maximum absolute delta tolerated on `NAV_UNIT` comparisons for this kernel's rounding.
    function maxNAVDelta() external view returns (NAV_UNIT);
}
