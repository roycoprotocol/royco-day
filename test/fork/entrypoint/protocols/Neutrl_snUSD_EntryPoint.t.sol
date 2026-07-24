// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test_EntryPointForkBase } from "../Test_EntryPointForkBase.t.sol";

/**
 * @title Neutrl_snUSD_EntryPoint
 * @notice The RoycoDayEntryPoint fork suite against the Neutrl snUSD mainnet market: ST/JT are the snUSD ERC4626
 *         vault share priced base(nUSD)->NAV via the RedStone feed, the LPT holds the {snUSD_share, USDC} Gyro
 *         E-CLP BPT, and the entry point is the production singleton the DeployScript wires. The inherited tests
 *         run the full request/execute/cancel lifecycle with hand-derived forfeiture numbers on the real assets
 * @dev Skips (like every config-driven fork suite) when MAINNET_RPC_URL is not configured
 */
contract Neutrl_snUSD_EntryPoint is Test_EntryPointForkBase {
    address internal constant NUSD_REDSTONE_ORACLE = 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95; // base(nUSD)->NAV feed

    function _marketName() internal pure override returns (string memory) {
        return "snUSD";
    }

    function _baseAssetToNavOracle() internal pure override returns (address) {
        return NUSD_REDSTONE_ORACLE;
    }

    function _forkBlockNumber() internal pure override returns (uint256) {
        return 25_400_000;
    }
}
