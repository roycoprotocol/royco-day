// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPool } from "../../../interfaces/external/aave/IPool.sol";
import { IPoolAddressesProvider } from "../../../interfaces/external/aave/IPoolAddressesProvider.sol";
import { IPoolDataProvider } from "../../../interfaces/external/aave/IPoolDataProvider.sol";
import { ExecutionModel, IRoycoKernel } from "../../../interfaces/kernel/IRoycoKernel.sol";
import { MAX_TRANCHE_UNITS, ZERO_TRANCHE_UNITS } from "../../../libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toTrancheUnits, toUint256 } from "../../../libraries/Units.sol";
import { RoycoKernel, SyncedAccountingState } from "../RoycoKernel.sol";

/**
 * @title AaveV3_JT_Kernel
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Junior tranche kernel for Aave V3 lending pool deposits
 * @dev Manages junior tranche deposits and withdrawals via the Aave V3 lending pool
 *      Deposited assets are supplied to the pool and aTokens are received
 *      Handles illiquidity gracefully by transferring aTokens when withdrawals fail
 */
abstract contract AaveV3_JT_Kernel is RoycoKernel {
    using SafeERC20 for IERC20;
    using UnitsMathLib for TRANCHE_UNIT;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant JT_DEPOSIT_EXECUTION_MODEL = ExecutionModel.SYNC;

    /// @notice Address of the Aave V3 pool
    address private immutable AAVE_V3_POOL;

    /// @notice Address of the Aave V3 pool addresses provider
    address private immutable AAVE_V3_POOL_ADDRESSES_PROVIDER;

    /// @notice Address of the Aave V3 pool addresses provider
    address private immutable JT_ASSET_ATOKEN;

    /// @notice Thrown when the JT base asset is not a supported reserve token in the Aave V3 Pool
    error UNSUPPORTED_RESERVE_TOKEN();

    /// @notice Thrown when a low-level call fails
    error FAILED_CALL();

    /// @notice Constructor for the Aave V3 junior tranche kernel
    /// @param _aaveV3Pool The address of the Aave V3 Pool
    constructor(address _aaveV3Pool) {
        // Ensure that the Aave V3 pool is not null
        require(_aaveV3Pool != address(0), NULL_ADDRESS());

        // Initialize the Aave V3 junior tranche kernel state
        // Ensure that the JT base asset is a supported reserve token in the Aave V3 Pool
        JT_ASSET_ATOKEN = IPool(_aaveV3Pool).getReserveAToken(JT_ASSET);
        require(JT_ASSET_ATOKEN != address(0), UNSUPPORTED_RESERVE_TOKEN());

        // Set the immutable addresses for the Aave V3 pool and addresses provider
        AAVE_V3_POOL = _aaveV3Pool;
        AAVE_V3_POOL_ADDRESSES_PROVIDER = address(IPool(_aaveV3Pool).ADDRESSES_PROVIDER());
    }

    /// @notice Initializes a kernel where the junior tranche is deployed into Aave V3 with a redemption delay
    function __AaveV3_JT_Kernel_init_unchained() internal onlyInitializing {
        // Extend a one time max approval to the Aave V3 pool for the JT's base asset
        IERC20(JT_ASSET).forceApprove(AAVE_V3_POOL, type(uint256).max);
    }

    /// @inheritdoc IRoycoKernel
    function jtPreviewDeposit(TRANCHE_UNIT _jtAssets)
        external
        view
        override
        onlyJuniorTranche
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated)
    {
        // Preview the deposit by converting the assets to NAV units and returning the NAV at which the shares will be minted
        valueAllocated = jtConvertTrancheUnitsToNAVUnits(_jtAssets);
        stateBeforeDeposit = _previewSyncTrancheAccounting();
    }

    /// @inheritdoc RoycoKernel
    function _getJuniorTrancheRawNAV() internal view override(RoycoKernel) returns (NAV_UNIT) {
        // The tranche's balance of the AToken is the total assets it is owed from the Aave pool
        /// @dev This does not treat illiquidity in the Aave pool as a loss: we assume that total lent and interest will be withdrawable at some point
        return jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(IERC20(JT_ASSET_ATOKEN).balanceOf(address(this))));
    }

    /// @inheritdoc RoycoKernel
    function _jtMaxDepositGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // Retrieve the Pool's data provider and asset
        IPoolDataProvider poolDataProvider = IPoolDataProvider(IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPoolDataProvider());

        // If the reserve asset is inactive, frozen, or paused, supplies are forbidden
        (uint256 decimals,,,,,,,, bool isActive, bool isFrozen) = poolDataProvider.getReserveConfigurationData(JT_ASSET);
        if (!isActive || isFrozen || poolDataProvider.getPaused(JT_ASSET)) return ZERO_TRANCHE_UNITS;

        // Get the supply cap for the reserve asset. If unset, the suppliable amount is unbounded
        (, uint256 supplyCap) = poolDataProvider.getReserveCaps(JT_ASSET);
        if (supplyCap == 0) return MAX_TRANCHE_UNITS;

        // Compute the total reserve assets supplied and accrued to the treasury
        (uint256 totalAccruedToTreasury, uint256 totalLent) = _getTotalAccruedToTreasuryAndLent(poolDataProvider, JT_ASSET);
        uint256 currentlySupplied = totalLent + totalAccruedToTreasury;
        // Supply cap was returned as whole tokens, so we must scale by underlying decimals
        supplyCap = supplyCap * (10 ** decimals);

        // If supply cap hit, no incremental supplies are permitted. Else, return the max suppliable amount within the cap.
        return toTrancheUnits((currentlySupplied >= supplyCap) ? 0 : (supplyCap - currentlySupplied));
    }

    /**
     * @notice Helper function to get the total accrued to treasury and total lent and interest from the pool data provider
     * @dev IPoolDataProvider.getReserveData returns a tuple of 11 words which saturates the stack
     * @dev Uses a low-level static call to the pool data provider to avoid stack too deep errors
     * @param _poolDataProvider The Aave V3 pool data provider
     * @param _asset The asset to get the total lent and interest data for
     * @return totalAccruedToTreasury The total assets accrued to the Aave treasury that exist in the lending pool
     * @return totalLent The total assets lent and owned by lenders of the pool
     */
    function _getTotalAccruedToTreasuryAndLent(
        IPoolDataProvider _poolDataProvider,
        address _asset
    )
        internal
        view
        returns (uint256 totalAccruedToTreasury, uint256 totalLent)
    {
        bytes memory data = abi.encodeCall(IPoolDataProvider.getReserveData, (_asset));
        bool success;
        assembly ("memory-safe") {
            // Load the free memory pointer, and allocate 0x60 bytes for the return data
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, 0x60))

            // Make the static call to the pool data provider
            success := staticcall(gas(), _poolDataProvider, add(data, 0x20), mload(data), ptr, 0x60)

            // Load the total accrued to treasury and total lent and interest from the return data
            // Refer IPoolDataProvider.getReserveData for the return data layout
            totalAccruedToTreasury := mload(add(ptr, 0x20))
            totalLent := mload(add(ptr, 0x40))
        }
        require(success, FAILED_CALL());
    }

    /// @inheritdoc RoycoKernel
    function _jtMaxWithdrawableGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // If the reserve asset is paused, withdrawals and A Token transfers are forbidden
        IPoolDataProvider poolDataProvider = IPoolDataProvider(IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPoolDataProvider());
        if (poolDataProvider.getPaused(JT_ASSET)) return ZERO_TRANCHE_UNITS;

        // Return the total tranche units (A Tokens) controlled by the kernel
        return toTrancheUnits(IERC20(JT_ASSET_ATOKEN).balanceOf(address(this)));
    }

    /// @inheritdoc RoycoKernel
    function _jtPreviewWithdraw(TRANCHE_UNIT _jtAssets) internal pure override(RoycoKernel) returns (TRANCHE_UNIT withdrawnJTAssets) {
        return _jtAssets;
    }

    /// @inheritdoc RoycoKernel
    function _jtDepositAssets(TRANCHE_UNIT _jtAssets) internal override(RoycoKernel) returns (NAV_UNIT jtDepositNAV) {
        // No fees or slippage on supplying to Aave V3
        jtDepositNAV = jtConvertTrancheUnitsToNAVUnits(_jtAssets);

        // Supply the specified assets to the pool
        // Max approval already given to the pool on initialization
        IPool(AAVE_V3_POOL).supply(JT_ASSET, toUint256(_jtAssets), address(this), 0);
    }

    /// @inheritdoc RoycoKernel
    function _jtWithdrawAssets(TRANCHE_UNIT _jtAssets, address _receiver) internal override(RoycoKernel) {
        // Try and withdraw the requested assets from the Aave pool
        (bool withdrawalSucceeded,) = AAVE_V3_POOL.call(abi.encodeCall(IPool.withdraw, (JT_ASSET, toUint256(_jtAssets), _receiver)));
        if (withdrawalSucceeded) return;

        // The Pool lacks the liquidity to withdraw the requested assets, transfer A Tokens instead
        IERC20(JT_ASSET_ATOKEN).safeTransfer(_receiver, toUint256(_jtAssets));
    }
}
