// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { IMaplePool } from "../interfaces/external/maple/IMaplePool.sol";
import { IMaplePoolManager } from "../interfaces/external/maple/IMaplePoolManager.sol";
import { WAD } from "../libraries/Constants.sol";
import { Math } from "../libraries/Units.sol";
import {
    IdenticalERC4626SharesToChainlinkOracleQuoter,
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
} from "./Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { RoycoKernel } from "./base/RoycoKernel.sol";

/**
 * @title MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in Maple pool V2 tokens (syrupUSDC, syrupUSDT, etc.)
 * @notice Tranche share transfers enforce the same restrictions as Maple Pool token transfers
 * @dev NAV computations employ the exit share price (including unrealized losses) to convert pool tokens to base assets (eg USDC) and then a chainlink (compatible) or an admin oracle set rate to convert base assets to NAV units
 */
contract MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel is Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel {
    using Math for uint256;

    /// @dev The function ID for the transfer function on the maple pool
    bytes32 private constant MAPLE_POOL_TRANSFER_FUNCTION_ID = "P:transfer";

    /// @dev The function ID for the transferFrom function on the maple pool
    bytes32 private constant MAPLE_POOL_TRANSFER_FROM_FUNCTION_ID = "P:transferFrom";

    /// @notice The address of the Maple pool's manager
    address public immutable MAPLE_POOL_MANAGER;

    /// @dev Thrown when the Maple pool manager rejects a transfer of shares
    error TRANSFER_REJECTED_BY_MAPLE_POOL_MANAGER(string errorMessage);

    /// @notice Constructs the kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoKernelConstructionParams memory _params) Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel(_params) {
        // Set the address of the Maple pool's manager
        MAPLE_POOL_MANAGER = IMaplePool(ST_ASSET).manager();
    }

    /**
     * @notice Returns the conversion rate from the Maple pool token (tranche units) to NAV units, scaled to WAD precision
     * @return maplePoolTokenToNAVUnitConversionRateWAD The conversion rate from the Maple pool token (tranche units) to NAV units, scaled to WAD precision
     */
    function getTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(IdenticalERC4626SharesToChainlinkOracleQuoter)
        returns (uint256 maplePoolTokenToNAVUnitConversionRateWAD)
    {
        // Fetch the conversion rate (using the exit share price) from the Maple pool token to its underlying asset, scaled to WAD precision
        uint256 maplePoolTokenToBaseAssetsConversionRateWAD = IMaplePool(ST_ASSET).convertToExitAssets(ERC4626_SHARES_TO_CONVERT_TO_ASSETS);

        // Resolve the vault base asset to NAV unit conversion rate, scaled to WAD precision
        uint256 baseAssetToNAVUnitConversionRateWAD = getStoredConversionRateWAD();
        // If the stored conversion rate is the sentinel value, query the oracle for the rate
        if (baseAssetToNAVUnitConversionRateWAD == SENTINEL_CONVERSION_RATE) baseAssetToNAVUnitConversionRateWAD = _getConversionRateFromOracleWAD();

        // Calculate the conversion rate from Maple pool tokens to NAV units, scaled to WAD precision
        maplePoolTokenToNAVUnitConversionRateWAD =
            maplePoolTokenToBaseAssetsConversionRateWAD.mulDiv(baseAssetToNAVUnitConversionRateWAD, WAD, Math.Rounding.Floor);
    }

    /// @inheritdoc RoycoKernel
    function _preTrancheBalanceUpdate(address _caller, address _from, address _to, uint256 _amount) internal view override(RoycoKernel) {
        // Preemptively return if this is a mint or redeem since the Maple pool checks permissions on minting/redeeming the underlying
        if (_from == address(0) || _to == address(0)) return;

        // Check the validity of the tranche shares transfer
        bool validTransfer;
        string memory errorMessage;
        // If this is a standard transfer, check the validity of the exact transfer call on the underlying Maple Pool
        if (_caller == _from) {
            (validTransfer, errorMessage) = IMaplePoolManager(MAPLE_POOL_MANAGER).canCall(MAPLE_POOL_TRANSFER_FUNCTION_ID, _caller, abi.encode(_to, _amount));
        }
        // If this is a transferFrom, check the validity of the exact transferFrom call on the underlying Maple Pool
        else {
            (validTransfer, errorMessage) =
                IMaplePoolManager(MAPLE_POOL_MANAGER).canCall(MAPLE_POOL_TRANSFER_FROM_FUNCTION_ID, _caller, abi.encode(_from, _to, _amount));
        }
        // Assert that the manager approves of this transfer
        require(validTransfer, TRANSFER_REJECTED_BY_MAPLE_POOL_MANAGER(errorMessage));
    }
}
