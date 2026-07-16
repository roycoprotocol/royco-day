// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { MarketState } from "../libraries/Types.sol";

/**
 * @title IYDM - Yield Distribution Model Interface
 * @notice Interface for yield distribution models that price the premium paid to a pool of capital for a service it provides to a tranche
 * @dev A YDM is a general-purpose premium model: it maps a single utilization input to the share of a tranche's yield paid out to the capital pool as a premium
 * @dev Utilization is the fraction of the pool's service capacity that is currently in use: the ratio of demand for the service the pool provides to the pool's capacity to supply it, scaled to WAD precision
 * @dev At zero utilization the service is unused and the capital is abundant, so it earns the least
 * @dev At WAD utilization demand equals the pool's full capacity, demand beyond capacity is reported above WAD and capped to WAD by the model
 * @dev The premium rises with utilization so that scarcer service is paid more, pulling additional capital into the pool
 * @dev The caller computes the relevant utilization and passes it in directly, so the model is agnostic to what the utilization measures
 */
interface IYDM {
    /// @dev Thrown when the initialization parameters of the YDM for a market are invalid
    error INVALID_YDM_INITIALIZATION();

    /// @dev Thrown when an accountant attempts to query the yield share without initializing the YDM
    error UNINITIALIZED_YDM();

    /**
     * @notice Previews and returns the share of a tranche's yield to pay the capital pool as a premium at the given utilization
     * @dev Does not mutate any state
     * @param _marketState The state of this Royco market (perpetual or fixed term), the curve only adapts in PERPETUAL
     * @param _utilizationWAD The utilization of the service the capital pool provides, scaled to WAD precision, the model caps it at WAD
     * @return yieldShareWAD The share of the tranche's yield paid to the capital pool as a premium, scaled to WAD precision
     *                       It is implied that (WAD - yieldShareWAD) is retained by the paying tranche, excluding any protocol fees
     */
    function previewYieldShare(MarketState _marketState, uint256 _utilizationWAD) external view returns (uint256 yieldShareWAD);

    /**
     * @notice Returns the share of a tranche's yield to pay the capital pool as a premium at the given utilization
     * @dev Can mutate state: the adaptive models translate their curve based on the elapsed time and utilization
     * @param _marketState The state of this Royco market (perpetual or fixed term), the curve only adapts in PERPETUAL
     * @param _utilizationWAD The utilization of the service the capital pool provides, scaled to WAD precision, the model caps it at WAD
     * @return yieldShareWAD The share of the tranche's yield paid to the capital pool as a premium, scaled to WAD precision
     *                       It is implied that (WAD - yieldShareWAD) is retained by the paying tranche, excluding any protocol fees
     */
    function yieldShare(MarketState _marketState, uint256 _utilizationWAD) external returns (uint256 yieldShareWAD);
}
