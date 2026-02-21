// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IYDM } from "../../src/interfaces/IYDM.sol";
import { DeployScript } from "../Deploy.s.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/// @dev Deploys an independent instance of the specified YDM
contract DeployYDMScript is DeployScript {
    /// @dev The YDM type to deploy an instance of
    YDMType ydmType = YDMType.AdaptiveCurve_V2;

    function run() external override {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        IYDM ydm = _deployYDM(ydmType);
        vm.stopBroadcast();
    }
}
