// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { IInsuranceCapitalLayer } from "../interfaces/external/reUSD/IInsuranceCapitalLayer.sol";
import { WAD_DECIMALS } from "../libraries/Constants.sol";
import { RoycoKernel } from "./base/RoycoKernel.sol";
import { IdenticalAssetsOracleQuoter } from "./base/quoter/base/IdenticalAssetsOracleQuoter.sol";

/**
 * @title ReUSD_ST_ReUSD_JT_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in reUSD
 * @notice The NAV can be expressed in any quote token supported by reUSD's Insurance Capital Layer (ICL)
 * @dev https://docs.re.xyz/insurance-capital-layers/what-is-reusd
 */
contract ReUSD_ST_ReUSD_JT_Kernel is RoycoKernel, IdenticalAssetsOracleQuoter {
    /// @notice The address of the reUSD token
    address public immutable REUSD;

    /// @notice The address of the token in which the NAV is expressed (typically USDC)
    address public immutable REUSD_QUOTE_TOKEN;

    /// @notice The address of the reUSD insurance capital layer
    address public immutable INSURANCE_CAPITAL_LAYER;

    /// @notice ICL input for reUSD exchange rate in quote tokens, scaled to WAD precision
    uint256 public immutable REUSD_AMOUNT_FOR_WAD_PRECISION_CONVERSION_RATE;

    /**
     * @notice Constructs the Royco kernel
     * @param _params The standard construction parameters for the Royco kernel
     * @param _reusd The address of the reUSD token
     * @param _reusdUsdQuoteToken The address of the token in which the NAV is expressed in
     * @param _insuranceCapitalLayer The address of the reUSD insurance capital layer
     */
    constructor(
        RoycoKernelConstructionParams memory _params,
        address _reusd,
        address _reusdUsdQuoteToken,
        address _insuranceCapitalLayer
    )
        RoycoKernel(_params)
    {
        // Set the reUSD specific state
        require(_reusd != address(0) && _reusdUsdQuoteToken != address(0) && _insuranceCapitalLayer != address(0), NULL_ADDRESS());
        REUSD = _reusd;
        REUSD_QUOTE_TOKEN = _reusdUsdQuoteToken;
        INSURANCE_CAPITAL_LAYER = _insuranceCapitalLayer;
        // ICL output = input * rate * 10^(QUOTE_DECIMALS - REUSD_DECIMALS)
        // With input = 10^(WAD_DECIMALS + REUSD_DECIMALS - QUOTE_DECIMALS), output = rate * WAD
        REUSD_AMOUNT_FOR_WAD_PRECISION_CONVERSION_RATE =
            10 ** (WAD_DECIMALS + IERC20Metadata(_reusd).decimals() - IERC20Metadata(_reusdUsdQuoteToken).decimals());
    }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     */
    function initialize(IRoycoKernel.RoycoKernelInitParams calldata _params) external initializer {
        // Initialize the base kernel state
        __RoycoKernel_init(_params);
        // The initial conversion rate is set to the sentinel value so that the reUSD -> REUSD_QUOTE_TOKEN conversion rate is queried directly from the insurance capital layer
        __IdenticalAssetsOracleQuoter_init_unchained(SENTINEL_CONVERSION_RATE);
    }

    /// @inheritdoc IdenticalAssetsOracleQuoter
    function _getConversionRateFromOracleWAD() internal view override returns (uint256) {
        return IInsuranceCapitalLayer(INSURANCE_CAPITAL_LAYER).convertFromShares(REUSD_QUOTE_TOKEN, REUSD_AMOUNT_FOR_WAD_PRECISION_CONVERSION_RATE);
    }
}
