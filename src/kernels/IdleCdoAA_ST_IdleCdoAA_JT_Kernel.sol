// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import { IIdleCDO } from "../interfaces/external/idle-finance/IIdleCDO.sol";
import { WAD_DECIMALS } from "../libraries/Constants.sol";
import { RoycoKernelInitParams } from "../libraries/RoycoKernelStorageLib.sol";
import { AtomicLiquidationFacility } from "./base/liquidation-facility/AtomicLiquidationFacility.sol";
import { IdenticalAssetsOracleQuoter } from "./base/quoter/base/IdenticalAssetsOracleQuoter.sol";
import {
    YieldBearingERC20_ST_YieldBearingERC20_JT_IdenticalAssetsOracleQuoter_Kernel
} from "./base/recipe/YieldBearingERC20_ST_YieldBearingERC20_JT_IdenticalAssetsOracleQuoter_Kernel.sol";

/**
 * @title IdleCdoAA_ST_IdleCdoAA_JT_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in an IdleCDO's AA tranche
 * @notice The NAV can be expressed in any quote token supported by an IdleCDO's AA tranche
 * @dev Example: Pareto's Falconx's Prime Brokerage Vault at https://app.pareto.credit/vault#0xC26A6Fa2C37b38E549a4a1807543801Db684f99C
 * @dev https://docs.idle.finance/
 */
contract IdleCdoAA_ST_IdleCdoAA_JT_Kernel is YieldBearingERC20_ST_YieldBearingERC20_JT_IdenticalAssetsOracleQuoter_Kernel, AtomicLiquidationFacility {
    /// @notice The address of the IdleCDO
    address public immutable IDLE_CDO;

    /// @notice The virtual price multiplier for the IdleCDO's AA tranche to convert to WAD precision
    uint256 public immutable IDLE_CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION;

    /// @notice Thrown when the AA tranche token is different from the ST and JT asset
    error CDO_AA_TRANCHE_TOKEN_MISMATCH();

    /// @notice Thrown when the IdleCDO address is null
    error NULL_IDLE_CDO_ADDRESS();

    /**
     * @notice Constructs the Royco kernel
     * @param _params The standard construction parameters for the Royco kernel
     * @param _idleCDO The address of the IdleCDO
     */
    constructor(
        RoycoKernelConstructionParams memory _params,
        address _idleCDO
    )
        YieldBearingERC20_ST_YieldBearingERC20_JT_IdenticalAssetsOracleQuoter_Kernel(_params)
    {
        require(_idleCDO != address(0), NULL_IDLE_CDO_ADDRESS());
        IDLE_CDO = _idleCDO;

        // Ensure that the AA tranche token is the same as the ST and JT assets for the IdleCDO
        address aaTrancheToken = IIdleCDO(IDLE_CDO).AATranche();
        require(aaTrancheToken == ST_ASSET && aaTrancheToken == JT_ASSET, CDO_AA_TRANCHE_TOKEN_MISMATCH());

        // Compute the virtual price multiplier for the IdleCDO's AA tranche to convert to WAD precision
        uint256 quoteTokenDecimals = IERC20Metadata(IIdleCDO(IDLE_CDO).token()).decimals();
        IDLE_CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION = 10 ** (WAD_DECIMALS - quoteTokenDecimals);
    }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     */
    function initialize(RoycoKernelInitParams calldata _params) external initializer {
        // The initial conversion rate is set to the sentinel value so that the reUSD -> REUSD_QUOTE_TOKEN conversion rate is queried directly from the insurance capital layer
        __YieldBearingERC20_ST_YieldBearingERC20_JT_IdenticalAssetsOracleQuoter_Kernel_init(_params, SENTINEL_CONVERSION_RATE);
    }

    /// @inheritdoc IdenticalAssetsOracleQuoter
    function _getConversionRateFromOracleWAD() internal view override returns (uint256) {
        // Virtual Price returns IdleCDO.token() decimals
        // We multiply the virtual price by the virtual price multiplier convert to WAD precision
        return IIdleCDO(IDLE_CDO).virtualPrice(ST_ASSET) * IDLE_CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION;
    }
}
