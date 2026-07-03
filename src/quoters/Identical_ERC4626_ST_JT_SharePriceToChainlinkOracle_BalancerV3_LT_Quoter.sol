// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { NAV_UNIT } from "../libraries/Units.sol";
import { RoycoDayQuoter } from "./base/RoycoDayQuoter.sol";
import {
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "./identical-st-jt/IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "./identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { BalancerV3_LT_Quoter } from "./liquidity-tranche/balancer-v3/BalancerV3_LT_Quoter.sol";

/**
 * @title Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Quoter
 * @author Waymont
 * @notice The market quoter for a Balancer V3 liquidity tranche kernel: the senior and junior tranches transfer in the same yield bearing ERC4626 shares (sUSDS, sUSDe, etc.), and the liquidity tranche's position (BPT) is valued against a Balancer V3 pool pairing the senior tranche share against a quote asset (USDC, srRoyUSDC, etc.)
 * @dev ST/JT NAV computations convert tranche units (ERC4626 shares) to base assets using the vault's exchange rate and then convert base assets to NAV units using a Chainlink (compatible) oracle or an admin set exchange rate
 * @dev LT NAV computations value the pool position (BPT) using a manipulation-resistant Balancer V3 oracle, and this quoter is the pool's senior share rate provider
 */
contract Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Quoter is
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter,
    BalancerV3_LT_Quoter
{
    /**
     * @notice Quoter-specific initialization parameters
     * @custom:field stAndJTQuoterParams - The senior/junior tranche ERC4626-shares-to-Chainlink quoter's parameters
     * @custom:field ltQuoterParams - The liquidity tranche Balancer V3 quoter's parameters
     */
    struct QuoterSpecificInitParams {
        IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
        BalancerV3_LT_Quoter.LT_QuoterSpecificParams ltQuoterParams;
    }

    /// @notice Constructs the quoter state and resolves the quote asset from the liquidity tranche's Balancer V3 pool
    /// @param _roycoDayKernel The kernel this quoter prices (its pool wiring is resolved from the kernel's LT asset)
    constructor(address _roycoDayKernel) BalancerV3_LT_Quoter(_roycoDayKernel) { }

    /**
     * @notice Initializes the Royco Day quoter and its ST/JT and liquidity tranche quoters
     * @param _initialAuthority The access manager that governs this quoter's restricted functions
     * @param _params The quoter-specific initialization parameters
     */
    function initialize(address _initialAuthority, QuoterSpecificInitParams calldata _params) external initializer {
        // Initialize the base access-managed and pausable state
        __RoycoBase_init(_initialAuthority);
        // Initialize the identical ERC4626 shares to Chainlink (compatible) oracle ST/JT quoter
        __IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter_init(_params.stAndJTQuoterParams);
        // Initialize the Balancer V3 liquidity tranche quoter
        __BalancerV3_LT_Quoter_init_unchained(_params.ltQuoterParams);
    }

    /// @inheritdoc RoycoDayQuoter
    function _cacheSTShareRate(NAV_UNIT _stEffectiveNAV, uint256 _stTotalSupplyAfterMints) internal override(RoycoDayQuoter, BalancerV3_LT_Quoter) {
        BalancerV3_LT_Quoter._cacheSTShareRate(_stEffectiveNAV, _stTotalSupplyAfterMints);
    }

    /// @inheritdoc RoycoDayQuoter
    function _initializeQuoterCache() internal override(RoycoDayQuoter, IdenticalAssets_ST_JT_Oracle_Quoter) {
        IdenticalAssets_ST_JT_Oracle_Quoter._initializeQuoterCache();
    }

    /// @inheritdoc RoycoDayQuoter
    function _clearQuoterCache() internal override(RoycoDayQuoter, IdenticalAssets_ST_JT_Oracle_Quoter) {
        IdenticalAssets_ST_JT_Oracle_Quoter._clearQuoterCache();
    }
}
