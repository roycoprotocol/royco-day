// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { NAV_UNIT } from "../libraries/Units.sol";
import { RoycoDayKernel } from "./base/RoycoDayKernel.sol";
import {
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "./base/quoter/identical-st-jt/IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "./base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { BalancerV3_LT_Quoter } from "./base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_Quoter.sol";

/**
 * @title Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in the same yield bearing ERC4626 shares (sUSDS, sUSDe, etc.), and the liquidity tranche provides secondary liquidity via a Balancer V3 pool pairing the senior tranche share against a quote asset (USDC, srRoyUSDC, etc.)
 * @dev ST/JT NAV computations convert tranche units (ERC4626 shares) to base assets using the vault's exchange rate and then convert base assets to NAV units using a Chainlink (compatible) oracle or an admin set exchange rate
 * @dev LT NAV computations value the pool position (BPT) using a manipulation-resistant Balancer V3 oracle, and the pool prices the senior share leg via this kernel's senior share rate provider
 */
contract Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Kernel is
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter,
    BalancerV3_LT_Quoter
{
    /**
     * @notice Kernel-specific initialization parameters, decoded from the deployment template's `kernelSpecificParams`.
     * @custom:field initialConversionRateWAD - The initial ERC4626 base-asset-to-NAV-asset conversion rate, scaled to WAD precision
     * @custom:field baseAssetToNavAssetOracle - The Chainlink oracle pricing the ERC4626 base asset in NAV accounting assets
     * @custom:field stalenessThresholdSeconds - The maximum age of a Chainlink answer before it is considered stale
     * @custom:field bptOracle - The manipulation-resistant Balancer V3 pool token (BPT) oracle used to value the liquidity tranche
     * @custom:field maxReinvestmentSlippageWAD - The maximum slippage tolerated when single-sided reinvesting the liquidity premium into the BPT, scaled to WAD precision
     */
    struct KernelSpecificInitParams {
        uint256 initialConversionRateWAD;
        address baseAssetToNavAssetOracle;
        uint48 stalenessThresholdSeconds;
        address bptOracle;
        uint64 maxReinvestmentSlippageWAD;
    }

    /// @notice Constructs the kernel state and resolves the quote asset from the liquidity tranche's Balancer V3 pool
    /// @param _params The standard construction parameters for the Royco Day kernel
    constructor(IRoycoDayKernel.RoycoDayKernelConstructionParams memory _params) RoycoDayKernel(_params) { }

    /**
     * @notice Initializes the Royco Day kernel and its ST/JT and liquidity tranche quoters
     * @param _standardParams The standard initialization parameters for the Royco Day kernel
     * @param _specificParams The kernel-specific (quoter) initialization parameters
     */
    function initialize(IRoycoDayKernel.RoycoDayKernelInitParams calldata _standardParams, KernelSpecificInitParams calldata _specificParams) external initializer {
        // Initialize the base kernel state
        __RoycoDayKernel_init(_standardParams);
        // Initialize the identical ERC4626 shares to Chainlink (compatible) oracle ST/JT quoter
        __IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter_init(
            _specificParams.initialConversionRateWAD, _specificParams.baseAssetToNavAssetOracle, _specificParams.stalenessThresholdSeconds
        );
        // Initialize the Balancer V3 liquidity tranche quoter
        __BalancerV3_LT_Quoter_init_unchained(_specificParams.bptOracle, _specificParams.maxReinvestmentSlippageWAD);
    }

    /**
     * @inheritdoc RoycoDayKernel
     * @dev Diamond resolution: only the Balancer V3 liquidity tranche quoter overrides this hook (to freeze the senior share rate for the
     *      pool's senior leg); the ST/JT quoter inherits the base no-op. Dispatches explicitly to the Balancer implementation.
     */
    function _cacheSTShareRate(NAV_UNIT _stEffectiveNAV, uint256 _stTotalSupplyAfterMints) internal override(RoycoDayKernel, BalancerV3_LT_Quoter) {
        BalancerV3_LT_Quoter._cacheSTShareRate(_stEffectiveNAV, _stTotalSupplyAfterMints);
    }

    /**
     * @inheritdoc RoycoDayKernel
     * @dev Diamond resolution: only the ST/JT quoter overrides this hook (to initialize its per-operation quoter cache); the Balancer V3
     *      quoter inherits the base no-op. Dispatches explicitly to the ST/JT implementation.
     */
    function _initializeQuoterCache() internal override(RoycoDayKernel, IdenticalAssets_ST_JT_Oracle_Quoter) {
        IdenticalAssets_ST_JT_Oracle_Quoter._initializeQuoterCache();
    }

    /**
     * @inheritdoc RoycoDayKernel
     * @dev Diamond resolution: only the ST/JT quoter overrides this hook (to clear its per-operation quoter cache); the Balancer V3
     *      quoter inherits the base no-op. Dispatches explicitly to the ST/JT implementation.
     */
    function _clearQuoterCache() internal override(RoycoDayKernel, IdenticalAssets_ST_JT_Oracle_Quoter) {
        IdenticalAssets_ST_JT_Oracle_Quoter._clearQuoterCache();
    }
}
