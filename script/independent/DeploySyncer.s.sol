// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoMarketSyncer } from "../../src/periphery/RoycoMarketSyncer.sol";
import { Create2DeployUtils } from "../utils/Create2DeployUtils.sol";
import { Script } from "lib/forge-std/src/Script.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title DeploySyncerScript
 * @notice Deployment script for the RoycoMarketSyncer contract
 * @dev Deploys both the implementation and ERC1967 proxy using deterministic CREATE2 deployment
 */
contract DeploySyncerScript is Script, Create2DeployUtils {
    /// @dev Deployment salt for Royco syncers
    bytes32 constant SYNCER_SALT_BASE = keccak256("ROYCO_SYNCER");

    /// @dev Address of the Royco factory deployed using CREATE2
    address constant ROYCO_FACTORY = 0x7cC6fB28eC7b5e7afC3cB3986141797ffc27253C;
    /// @dev Addresses of the market kernels to initially add the syncer
    address[] MARKET_KERNELS;

    // Whether to print deployment parameters
    bool ENABLE_LOGGING = false;

    function run() external {
        // Deploy the syncer
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deploySyncer(ROYCO_FACTORY, MARKET_KERNELS, deployerPrivateKey);
    }

    /**
     * @notice Deploys a RoycoMarketSyncer implementation and proxy
     * @dev Uses CREATE2 for deterministic deployment addresses
     * @param _roycoFactory The Royco factory to use as the access manager for the syncer
     * @param _marketKernels The initial market kernels to register with the syncer
     * @param deployerPrivateKey The private key to use for executing the deployment
     * @return syncer The address of the deployed syncer proxy
     */
    function deploySyncer(address _roycoFactory, address[] memory _marketKernels, uint256 deployerPrivateKey) public returns (address syncer) {
        vm.startBroadcast(deployerPrivateKey);
        // Deploy the syncer implementation
        (address syncerImplAddr, bool alreadyDeployed) = deployWithSanityChecks(SYNCER_SALT_BASE, type(RoycoMarketSyncer).creationCode, false);
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) {
                console2.log("Syncer Implementation already deployed at:", syncerImplAddr);
            } else {
                console2.log("Syncer Implementation deployed at:", syncerImplAddr);
            }
        }

        // Deploy the syncer proxy
        (syncer, alreadyDeployed) = deployWithSanityChecks(
            SYNCER_SALT_BASE, getERC1967ProxyCreationCode(syncerImplAddr, abi.encodeCall(RoycoMarketSyncer.initialize, (_roycoFactory, _marketKernels))), false
        );
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) {
                console2.log("Syncer proxy already deployed at:", syncer);
            } else {
                console2.log("Syncer proxy deployed at:", syncer);
            }
        }
        vm.stopBroadcast();
    }
}
