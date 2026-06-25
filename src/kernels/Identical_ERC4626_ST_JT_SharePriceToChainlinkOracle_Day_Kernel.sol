// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../libraries/Units.sol";
import { RoycoDayKernel } from "./base/RoycoDayKernel.sol";
import { IdenticalERC4626SharesToChainlinkOracleQuoter } from "./base/quoter/IdenticalERC4626SharesToChainlinkOracleQuoter.sol";

/**
 * @title Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Day_Kernel
 * @notice Concrete Royco Day kernel for a market whose senior and junior tranches share the same
 *         ERC4626 vault share (priced share->base via `convertToAssets`, base->NAV via a Chainlink
 *         oracle), and whose liquidity tranche holds the Balancer E-CLP BPT paired against a quote asset.
 */
contract Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Day_Kernel is IdenticalERC4626SharesToChainlinkOracleQuoter {
    /// @notice Kernel-specific (quoter) initialization parameters, decoded from the deployment template's `kernelSpecificParams`.
    /// @custom:field initialConversionRateWAD - The initial ERC4626 base-asset-to-NAV-asset conversion rate, scaled to WAD precision
    /// @custom:field baseAssetToNavAssetOracle - The Chainlink oracle pricing the ERC4626 base asset in NAV accounting assets
    /// @custom:field stalenessThresholdSeconds - The maximum age of a Chainlink answer before it is considered stale
    struct KernelInitParams {
        uint256 initialConversionRateWAD;
        address baseAssetToNavAssetOracle;
        uint48 stalenessThresholdSeconds;
    }

    /// @notice Sets the immutable tranche/asset/accountant wiring on the base kernel.
    /// @param _cp The standard kernel construction parameters (tranches, assets, accountant, quote asset, BPT).
    constructor(IRoycoDayKernel.RoycoDayKernelConstructionParams memory _cp) RoycoDayKernel(_cp) { }

    /// @notice Initializes the kernel and its ERC4626-shares-to-Chainlink quoter.
    /// @param _kip The base kernel initialization parameters (authority, fee recipient, bonus, blacklist).
    /// @param _qp The quoter initialization parameters.
    function initialize(IRoycoDayKernel.RoycoDayKernelInitParams calldata _kip, KernelInitParams calldata _qp) external initializer {
        __RoycoDayKernel_init(_kip);
        __IdenticalERC4626SharesToChainlinkOracleQuoter_init(_qp.initialConversionRateWAD, _qp.baseAssetToNavAssetOracle, _qp.stalenessThresholdSeconds);
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev The LT asset is the Balancer BPT, valued by the E-CLP oracle (P4). LT deposits/redeems are disabled until
    ///      then, so the sync never sources `ltRawNAV` through this path; return 0 as a coverage-neutral placeholder.
    function ltConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT) public view override(RoycoDayKernel) returns (NAV_UNIT) {
        return ZERO_NAV_UNITS;
    }

    /// @inheritdoc IRoycoDayKernel
    /// @dev Placeholder mirroring `ltConvertTrancheUnitsToNAVUnits`: returns 0 until the Balancer E-CLP oracle adapter
    ///      (P4) is wired. LT deposits/redeems are disabled, so this conversion is never exercised by the engine yet.
    function ltConvertNAVUnitsToTrancheUnits(NAV_UNIT) public view override(RoycoDayKernel) returns (TRANCHE_UNIT) {
        return ZERO_TRANCHE_UNITS;
    }
}
