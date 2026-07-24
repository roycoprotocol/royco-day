// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { BalancerPoolToken } from "../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../libraries/Units.sol";
import { RoycoDayKernel } from "./base/RoycoDayKernel.sol";
import { IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter } from "./base/quoter/identical-st-jt/IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "./base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "./base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";

/**
 * @title Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in the same yield bearing asset such as a Pendle PT (PT-USDe, etc.), and the liquidity tranche provides secondary liquidity via a Balancer V3 pool pairing the senior tranche share against a quote asset (USDC, srRoyUSDC, etc.)
 * @dev ST/JT NAV computations convert tranche units to reference assets (PT-USDe to USDe, etc.) using a Chainlink (compatible) oracle and then convert reference assets to NAV units using an admin set rate
 * @dev LT NAV computations value the pool position (BPT) using a manipulation-resistant Balancer V3 oracle, and the pool prices the senior share leg via this kernel's senior share rate provider
 */
contract Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel is
    IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter,
    BalancerV3_LT_BPTOracle_Quoter
{
    /**
     * @notice Kernel-specific initialization parameters
     * @custom:field stAndJTQuoterParams - The senior/junior tranche Chainlink-to-admin-oracle quoter's parameters
     * @custom:field ltQuoterParams - The liquidity tranche Balancer V3 quoter's parameters
     */
    struct KernelSpecificInitParams {
        IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
        BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams ltQuoterParams;
    }

    /// @notice Constructs the kernel state and resolves the quote asset from the liquidity tranche's Balancer V3 pool
    /// @param _params The standard construction parameters for the Royco Day kernel
    constructor(IRoycoDayKernel.RoycoDayKernelConstructionParams memory _params)
        RoycoDayKernel(_params)
        BalancerV3_LT_BPTOracle_Quoter(BalancerPoolToken(_params.ltAsset).getVault())
    { }

    /**
     * @notice Initializes the Royco Day kernel and its ST/JT and liquidity tranche quoters
     * @param _standardParams The standard initialization parameters for the Royco Day kernel
     * @param _specificParams The kernel-specific initialization parameters
     */
    function initialize(
        IRoycoDayKernel.RoycoDayKernelInitParams calldata _standardParams,
        KernelSpecificInitParams calldata _specificParams
    )
        external
        initializer
    {
        // Initialize the base kernel state
        __RoycoDayKernel_init(_standardParams);
        // Initialize the identical assets Chainlink (compatible) oracle to admin set rate ST/JT quoter
        __IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter_init(_specificParams.stAndJTQuoterParams);
        // Initialize the Balancer V3 liquidity tranche quoter
        __BalancerV3_LT_BPTOracle_Quoter_init_unchained(_specificParams.ltQuoterParams);
    }

    /// @inheritdoc RoycoDayKernel
    function _initializeQuoterCache() internal override(RoycoDayKernel, IdenticalAssets_ST_JT_Oracle_Quoter) {
        IdenticalAssets_ST_JT_Oracle_Quoter._initializeQuoterCache();
    }

    /// @inheritdoc RoycoDayKernel
    function _isTrancheShareCustodian(address _account) internal view override(RoycoDayKernel, BalancerV3_LT_BPTOracle_Quoter) returns (bool) {
        return BalancerV3_LT_BPTOracle_Quoter._isTrancheShareCustodian(_account);
    }

    /// @inheritdoc RoycoDayKernel
    /// @dev The two quoter paths both reach the kernel base, so the ST/JT quoter's pricing is selected explicitly
    function convertCollateralAssetsToValue(TRANCHE_UNIT _collateralAssets)
        public
        view
        override(RoycoDayKernel, IdenticalAssets_ST_JT_Oracle_Quoter)
        returns (NAV_UNIT value)
    {
        return IdenticalAssets_ST_JT_Oracle_Quoter.convertCollateralAssetsToValue(_collateralAssets);
    }

    /// @inheritdoc RoycoDayKernel
    function convertValueToCollateralAssets(NAV_UNIT _value)
        public
        view
        override(RoycoDayKernel, IdenticalAssets_ST_JT_Oracle_Quoter)
        returns (TRANCHE_UNIT collateralAssets)
    {
        return IdenticalAssets_ST_JT_Oracle_Quoter.convertValueToCollateralAssets(_value);
    }


    /// @inheritdoc RoycoDayKernel
    function setSequencerUptimeFeed(
        address _sequencerUptimeFeed,
        uint48 _gracePeriodSeconds
    )
        external
        override(RoycoDayKernel, IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter)
        restricted
    {
        _setSequencerUptimeFeed(_sequencerUptimeFeed, _gracePeriodSeconds);
    }

    /// @inheritdoc RoycoDayKernel
    function _setSequencerUptimeFeed(
        address _sequencerUptimeFeed,
        uint48 _gracePeriodSeconds
    )
        internal
        override(RoycoDayKernel, IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter)
    {
        IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter._setSequencerUptimeFeed(_sequencerUptimeFeed, _gracePeriodSeconds);
    }
}
