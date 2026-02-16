// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TRANCHE_UNIT } from "../libraries/Units.sol";

/**
 * @title IRoycoLiquidator
 * @notice Interface for liquidator contracts that receive callback during liquidation
 */
interface IRoycoLiquidator {
    /**
     * @notice Called by the kernel during liquidation after assets are transferred to the liquidator
     * @param _stAssets The amount of ST assets transferred to the liquidator (demanded assets + bonus)
     * @param _jtAssets The amount of JT assets transferred to the liquidator (demanded assets + bonus)
     * @param _liquidationCallbackData Arbitrary data passed through from the liquidate call
     */
    function onRoycoLiquidate(TRANCHE_UNIT _stAssets, TRANCHE_UNIT _jtAssets, bytes calldata _liquidationCallbackData) external;
}
