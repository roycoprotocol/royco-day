// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IMaplePool
/// @notice Abridged interface for a Maple Pool
interface IMaplePool {
    /**
     *  @dev    The address of the account that is allowed to update the vesting schedule.
     *  @return manager_ The address of the pool manager.
     */
    function manager() external view returns (address manager_);

    /**
     *  @dev    Returns the amount of exit assets for the input amount.
     *  @param  shares_ The amount of shares to convert to assets.
     *  @return assets_ Amount of assets able to be exited.
     */
    function convertToExitAssets(uint256 shares_) external view returns (uint256 assets_);
}
