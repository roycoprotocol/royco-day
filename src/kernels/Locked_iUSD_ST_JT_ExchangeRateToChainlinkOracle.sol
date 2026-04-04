// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ILockingController } from "../interfaces/external/infinifi/ILockingController.sol";
import { IYieldSharingV2 } from "../interfaces/external/infinifi/IYieldSharingV2.sol";
import { WAD } from "../libraries/Constants.sol";
import {
    IdenticalERC4626SharesToChainlinkOracleQuoter,
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
} from "./Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { AssetClaims, Math, RoycoKernel, SyncedAccountingState, TrancheType } from "./base/RoycoKernel.sol";
import { IAccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

/**
 * @title Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle
 * @author Waymont
 * @notice The senior and junior tranches transfer in Infinifi Locked iUSD tokens with the same unwinding epochs
 * @notice Tranche share transfers enforce the same restrictions as Maple Pool token transfers
 * @dev NAV computations employ the exchange rate between locked iUSD tokens to iUSD and then a chainlink (compatible) or an admin oracle set rate to convert iUSD to NAV units
 */
contract Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle is Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel {
    using Math for uint256;
    /// @dev The role of the finance manager responsible for synchronizing accounting state for the InfiniFi protocol
    bytes32 private constant FINANCE_MANAGER_ROLE = keccak256("FINANCE_MANAGER");

    /// @notice The address of InfiniFi core contract
    address public immutable INFINIFI_CORE;

    /// @notice The address of InfiniFi's locking controller
    address public immutable INFINIFI_LOCKING_CONTROLLER;

    /// @notice The unwinding epochs for the locked iUSD token (tranche assets)
    uint32 private immutable UNWINDING_EPOCHS;

    /// @dev Thrown when the tranche assets (locked iUSD) aren't the share token for the specified unwinding epochs
    error TRANCHE_ASSET_AND_UNWINDING_EPOCHS_MISMATCH();

    /**
     * @notice Constructs the kernel state
     * @param _params The standard construction parameters for the Royco kernel
     * @param _lockingController The address of InfiniFi's locking controller
     * @param _unwindingEpochs The address of InfiniFi's locking controller
     */
    constructor(
        RoycoKernelConstructionParams memory _params,
        address _lockingController,
        uint32 _unwindingEpochs
    )
        Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel(_params)
    {
        // Ensure that the tranche assets are the canonical locked iUSD token for the specified unwinding epoch
        require(ILockingController(_lockingController).shareToken(_unwindingEpochs) == ST_ASSET, TRANCHE_ASSET_AND_UNWINDING_EPOCHS_MISMATCH());
        // Set the address of the InfiniFi core and locking controller contracts
        INFINIFI_CORE = ILockingController(_lockingController).core();
        INFINIFI_LOCKING_CONTROLLER = _lockingController;
        UNWINDING_EPOCHS = _unwindingEpochs;
    }

    /**
     * @notice Returns the conversion rate from the InfiniFi locked iUSD token (tranche units) to NAV units, scaled to WAD precision
     * @return liUSDToNAVUnitConversionRateWAD The conversion rate from the InfiniFi locked iUSD token (tranche units) to NAV units, scaled to WAD precision
     */
    function getTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(IdenticalERC4626SharesToChainlinkOracleQuoter)
        returns (uint256 liUSDToNAVUnitConversionRateWAD)
    {
        // Fetch the conversion rate from the InfiniFi locked iUSD token to iUSD
        // NOTE: The output is already scaled to WAD precision
        uint256 liUSDToIUSDNAVUnitConversionRateWAD = ILockingController(INFINIFI_LOCKING_CONTROLLER).exchangeRate(UNWINDING_EPOCHS);

        // Resolve the iUSD to NAV unit conversion rate, scaled to WAD precision
        uint256 iUSDToNAVUnitConversionRateWAD = getStoredConversionRateWAD();
        // If the stored conversion rate is the sentinel value, query the oracle for the rate
        if (iUSDToNAVUnitConversionRateWAD == SENTINEL_CONVERSION_RATE) iUSDToNAVUnitConversionRateWAD = _getConversionRateFromOracleWAD();

        // Calculate the conversion rate from Maple pool tokens to NAV units, scaled to WAD precision
        liUSDToNAVUnitConversionRateWAD = liUSDToIUSDNAVUnitConversionRateWAD.mulDiv(iUSDToNAVUnitConversionRateWAD, WAD, Math.Rounding.Floor);
    }

    /// @inheritdoc RoycoKernel
    /// @dev Synchronizes InfiniFi's internal accounting before synchronizing tranche accounting, ensuring fresh NAVs
    function _preOpSyncTrancheAccounting() internal override(RoycoKernel) returns (SyncedAccountingState memory) {
        _syncInfinifiAccounting();
        return super._preOpSyncTrancheAccounting();
    }

    /// @inheritdoc RoycoKernel
    /// @dev Synchronizes InfiniFi's internal accounting before synchronizing tranche accounting, ensuring fresh NAVs
    function _preOpSyncTrancheAccounting(TrancheType _trancheType)
        internal
        override(RoycoKernel)
        returns (SyncedAccountingState memory, AssetClaims memory, uint256)
    {
        _syncInfinifiAccounting();
        return super._preOpSyncTrancheAccounting(_trancheType);
    }

    /// @dev Synchronizes the accounting for all InfiniFi tokens, ensuring the exchange rates are fresh
    function _syncInfinifiAccounting() internal {
        IYieldSharingV2(IAccessControlEnumerable(INFINIFI_CORE).getRoleMember(FINANCE_MANAGER_ROLE, 0)).accrue();
    }
}
