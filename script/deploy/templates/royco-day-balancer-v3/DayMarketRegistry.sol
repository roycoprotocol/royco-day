// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Market_APYX } from "./markets/Market_APYX.sol";
import { Market_DMG } from "./markets/Market_DMG.sol";
import { Market_DUSD } from "./markets/Market_DUSD.sol";
import { Market_FalconX } from "./markets/Market_FalconX.sol";
import { Market_SUSDai } from "./markets/Market_SUSDai.sol";
import { Market_SnUSD } from "./markets/Market_SnUSD.sol";
import { Market_SrRoyUSDC } from "./markets/Market_SrRoyUSDC.sol";

/**
 * @title DayMarketRegistry
 * @notice The aggregate registry for the Royco Day Balancer V3 template family: one market per file, all served
 *         through the shared name-keyed getter with its chain guard, override seam, and mined-market-id registry.
 */
contract DayMarketRegistry is Market_SnUSD, Market_SrRoyUSDC, Market_FalconX, Market_APYX, Market_DMG, Market_DUSD, Market_SUSDai {
    constructor() {
        _initializeSnUsdMarket();
        _initializeSrRoyUsdcMarket();
        _initializeFalconXMarket();
        _initializeApyxMarket();
        _initializeDmgMarket();
        _initializeDusdMarket();
        _initializeSUsdaiMarket();
        _initializeMinedMarketIds();
    }
}
