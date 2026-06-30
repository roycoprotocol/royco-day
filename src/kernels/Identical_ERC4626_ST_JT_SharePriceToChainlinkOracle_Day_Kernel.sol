// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../libraries/Units.sol";
import { RoycoDayKernel } from "./base/RoycoDayKernel.sol";
import { IdenticalERC4626Shares_ST_JT_ToChainlinkOracleQuoter } from "./base/quoter/identical-st-jt/IdenticalERC4626Shares_ST_JT_ToChainlinkOracleQuoter.sol";

/**
 * @title Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Day_Kernel
 * @notice Concrete Royco Day kernel for a market whose senior and junior tranches share the same
 *         ERC4626 vault share (priced share->base via `convertToAssets`, base->NAV via a Chainlink
 *         oracle), and whose liquidity tranche holds the Balancer E-CLP pool position paired against a quote asset.
 */
contract Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Day_Kernel is IdenticalERC4626Shares_ST_JT_ToChainlinkOracleQuoter {
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
    /// @param _cp The standard kernel construction parameters (tranches, assets, accountant, quote asset, LT pool position).
    constructor(IRoycoDayKernel.RoycoDayKernelConstructionParams memory _cp) RoycoDayKernel(_cp) { }

    /// @notice Initializes the kernel and its ERC4626-shares-to-Chainlink quoter.
    /// @param _kip The base kernel initialization parameters (authority, fee recipient, bonus, blacklist).
    /// @param _qp The quoter initialization parameters.
    function initialize(IRoycoDayKernel.RoycoDayKernelInitParams calldata _kip, KernelInitParams calldata _qp) external initializer {
        __RoycoDayKernel_init(_kip);
        __IdenticalERC4626Shares_ST_JT_ToChainlinkOracleQuoter_init(_qp.initialConversionRateWAD, _qp.baseAssetToNavAssetOracle, _qp.stalenessThresholdSeconds);
    }

    /// @inheritdoc IRoycoDayKernel
    function ltConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT) public view override(RoycoDayKernel) returns (NAV_UNIT) {
        return ZERO_NAV_UNITS;
    }

    /// @inheritdoc IRoycoDayKernel
    function ltConvertNAVUnitsToTrancheUnits(NAV_UNIT) public view override(RoycoDayKernel) returns (TRANCHE_UNIT) {
        return ZERO_TRANCHE_UNITS;
    }

    /// @notice Thrown when an LT liquidity-venue operation is invoked on a kernel that has no Balancer venue wired yet (P4)
    error LIQUIDITY_VENUE_NOT_IMPLEMENTED();

    /// @inheritdoc RoycoDayKernel
    function _addLiquidity(uint256, uint256, TRANCHE_UNIT) internal override(RoycoDayKernel) returns (TRANCHE_UNIT) {
        revert LIQUIDITY_VENUE_NOT_IMPLEMENTED();
    }

    /// @inheritdoc RoycoDayKernel
    function _removeLiquidity(TRANCHE_UNIT, uint256, uint256, address) internal override(RoycoDayKernel) returns (uint256, uint256) {
        revert LIQUIDITY_VENUE_NOT_IMPLEMENTED();
    }

    /// @inheritdoc RoycoDayKernel
    /// @dev No Balancer liquidity venue is wired on this kernel yet (P4): the multi-asset deposit preview's venue-add
    ///      simulation is unreachable. Revert defensively.
    function _previewAddLiquidity(uint256, uint256) internal override(RoycoDayKernel) returns (TRANCHE_UNIT) {
        revert LIQUIDITY_VENUE_NOT_IMPLEMENTED();
    }

    /// @inheritdoc RoycoDayKernel
    /// @dev No Balancer liquidity venue is wired on this kernel yet (P4): the multi-asset redeem preview's venue-removal
    ///      simulation is unreachable. Revert defensively.
    function _previewRemoveLiquidity(TRANCHE_UNIT) internal override(RoycoDayKernel) returns (uint256, uint256) {
        revert LIQUIDITY_VENUE_NOT_IMPLEMENTED();
    }

    /// @inheritdoc RoycoDayKernel
    /// @dev No Balancer liquidity venue is wired on this kernel yet (P4): this kernel will eventually inherit BalancerV3_LT_Quoter, which resolves the quote asset from its pool. Until then there is no quote asset to resolve
    function QUOTE_ASSET() external view override(RoycoDayKernel) returns (address) {
        revert("QUOTE_ASSET: no liquidity venue wired (pending BalancerV3_LT_Quoter, P4)");
    }

    /// @inheritdoc RoycoDayKernel
    /// @dev No Balancer liquidity venue is wired on this kernel yet (P4): the LDM pays no liquidity premium while the LT is
    ///      disabled, so no premium ST shares are ever minted and this reinvestment hook is unreachable in practice. It is a
    ///      no-op (never a revert) so that, even if reached, the surrounding accounting sync can never brick: the premium simply
    ///      stays staged in the kernel until a venue is wired.
    function _attemptLiquidityPremiumReinvestment(uint256, NAV_UNIT, uint256) internal override(RoycoDayKernel) { }
}
