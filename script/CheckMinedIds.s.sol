// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// Throwaway diagnostic, delete after use: prints the predicted factories and checks the baked prod marketId sorting.
import { CREATE3 } from "../lib/solady/src/utils/CREATE3.sol";
import { TAG_ST_PROXY } from "../src/factory/templates/base/Constants.sol";
import { DeployScript } from "./Deploy.s.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

contract CheckMinedIds is DeployScript {
    function check() external view {
        address prodFactory = _predictFactoryProxy(DEPLOYER, false);
        address localFactory = _predictFactoryProxy(TEST_HARNESS_DEPLOYER, false);
        address testEnvFactory = _predictFactoryProxy(DEPLOYER, true);
        console2.log("prod factory   ", prodFactory);
        console2.log("local factory  ", localFactory);
        console2.log("testenv factory", testEnvFactory);

        bytes32 prodId = _marketIds[keccak256(bytes(SNUSD))][prodFactory];
        bytes32 salt = keccak256(abi.encodePacked("ROYCO_MARKET_", prodId, TAG_ST_PROXY));
        address st = CREATE3.predictDeterministicAddress(salt, prodFactory);
        console2.log("prod ST proxy  ", st);
        console2.log("prod id sorts below USDC:", uint160(st) < uint160(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));
        bytes32 minedProd = _mineMarketId(SNUSD, prodFactory, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        console2.log("freshly mined prod id:");
        console2.logBytes32(minedProd);
        console2.log("local id:");
        console2.logBytes32(_marketIds[keccak256(bytes(SNUSD))][localFactory]);
    }
}
