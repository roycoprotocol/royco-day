// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BalancerV3_LT_PreviewQuoter } from "./base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_PreviewQuoter.sol";

/**
 * @title Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Lens
 * @notice Concrete read-only lens for the `Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Kernel`.
 * @dev All state/config/conversions are read from the kernel through its interface (venue-agnostic base), and the
 *      Balancer V3 venue previews come from `BalancerV3_LT_PreviewQuoter`. Deploy one per market, pointed at the kernel.
 */
contract Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Lens is BalancerV3_LT_PreviewQuoter {
    /// @param _roycoDayKernel The kernel this lens reads from (its pool wiring is resolved from the kernel's LT asset)
    constructor(address _roycoDayKernel) BalancerV3_LT_PreviewQuoter(_roycoDayKernel) { }
}
