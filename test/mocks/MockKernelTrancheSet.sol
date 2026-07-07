// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title MockKernelTrancheSet
 * @notice Kernel stand-in exposing only the three tranche getters the factory's getMarket view reads, so
 *         factory-registry tests can wire arbitrary tranche sets without deploying a full kernel
 */
contract MockKernelTrancheSet {
    /// @notice The senior tranche this kernel stand-in reports
    address public immutable SENIOR_TRANCHE;

    /// @notice The junior tranche this kernel stand-in reports
    address public immutable JUNIOR_TRANCHE;

    /// @notice The liquidity tranche this kernel stand-in reports
    address public immutable LIQUIDITY_TRANCHE;

    /**
     * @notice Pins the three tranche addresses this stand-in reports
     * @param _seniorTranche The senior tranche address
     * @param _juniorTranche The junior tranche address
     * @param _liquidityTranche The liquidity tranche address
     */
    constructor(address _seniorTranche, address _juniorTranche, address _liquidityTranche) {
        SENIOR_TRANCHE = _seniorTranche;
        JUNIOR_TRANCHE = _juniorTranche;
        LIQUIDITY_TRANCHE = _liquidityTranche;
    }
}
