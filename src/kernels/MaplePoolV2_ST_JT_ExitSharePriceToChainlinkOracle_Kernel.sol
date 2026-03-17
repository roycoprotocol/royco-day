// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { IMaplePool } from "../interfaces/external/maple/IMaplePool.sol";
import { IMaplePoolManager } from "../interfaces/external/maple/IMaplePoolManager.sol";
import { IMaplePoolPermissionManager } from "../interfaces/external/maple/IMaplePoolPermissionManager.sol";
import { WAD } from "../libraries/Constants.sol";
import { TRANCHE_UNIT } from "../libraries/Units.sol";
import {
    IdenticalERC4626SharesToChainlinkOracleQuoter,
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
} from "./Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { AssetClaims, IRoycoVaultTranche, Math, RoycoKernel } from "./base/RoycoKernel.sol";

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

    /// @dev Thrown when the Maple pool's permission manager rejects a transfer of shares
    error TRANSFER_REJECTED_BY_MAPLE_PERMISSION_MANAGER();

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

        // Resolve the Maple pool token's base asset to NAV unit conversion rate, scaled to WAD precision
        uint256 baseAssetToNAVUnitConversionRateWAD = getStoredConversionRateWAD();
        // If the stored conversion rate is the sentinel value, query the oracle for the rate
        if (baseAssetToNAVUnitConversionRateWAD == SENTINEL_CONVERSION_RATE) baseAssetToNAVUnitConversionRateWAD = _getConversionRateFromOracleWAD();

        // Calculate the conversion rate from Maple pool tokens to NAV units, scaled to WAD precision
        maplePoolTokenToNAVUnitConversionRateWAD =
            maplePoolTokenToBaseAssetsConversionRateWAD.mulDiv(baseAssetToNAVUnitConversionRateWAD, WAD, Math.Rounding.Floor);
    }

    /// @inheritdoc RoycoKernel
    /// @dev Simulates Maple pool token transfer permissions as a compliance proxy
    function _preTrancheBalanceUpdate(address _caller, address _from, address _to, uint256) internal view override(RoycoKernel) {
        // Preemptively return when minting shares to the caller (deposit to self), since the caller and kernel addresses are validated on the pool token transfer on deposit
        if (_from == address(0) && _caller == _to) return;

        // Retrieve the Maple pool's permission manager
        // NOTE: This address must be queried at runtime since it is mutable
        IMaplePoolPermissionManager permissionManager = IMaplePoolPermissionManager(IMaplePoolManager(MAPLE_POOL_MANAGER).poolPermissionManager());

        // Determine whether the caller is the owner of the tranche shares (mints are treated as owner operations)
        bool callerIsOwner = _from == address(0) || _caller == _from;

        // Build the users array based on the operation type
        address[] memory users = new address[](2);
        if (_to == address(0)) {
            // Redemptions: validate the owner (and the approved party if this is a delegated redemption)
            // NOTE: The actual receiver of the Maple pool tokens is validated on the kernel to receiver transfer
            users[0] = _from;
            if (callerIsOwner) {
                // If the caller is the owner, we only need to check the from address so set the users array length to 1
                assembly ("memory-safe") {
                    mstore(users, 1)
                }
            } else {
                users[1] = _caller;
            }
        } else {
            // Mints/transfers/transferFroms: validate sender and recipient
            users[0] = callerIsOwner ? _caller : _from;
            users[1] = _to;
        }

        // Assert that the parties have the permissions to execute this transfer
        require(
            permissionManager.hasPermission(
                MAPLE_POOL_MANAGER, users, (callerIsOwner ? MAPLE_POOL_TRANSFER_FUNCTION_ID : MAPLE_POOL_TRANSFER_FROM_FUNCTION_ID)
            ),
            TRANSFER_REJECTED_BY_MAPLE_PERMISSION_MANAGER()
        );
    }
}
