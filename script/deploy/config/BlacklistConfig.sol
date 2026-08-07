// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { EnvConfig } from "./EnvConfig.sol";

/**
 * @title BlacklistConfig
 * @notice The blacklist deployment's own configuration: the canonical Chainalysis sanctions oracle per chain.
 */
abstract contract BlacklistConfig is EnvConfig {
    /// @notice Returns the canonical Chainalysis sanctions oracle for the given chain.
    function getChainalysisSanctionsList(uint256 _chainId) public pure returns (address) {
        // Chainalysis deploys its sanctions oracle at the same address on most chains; Base is the exception.
        if (_chainId == 1 || _chainId == 43_114 || _chainId == 42_161) {
            return 0x40C57923924B5c5c5455c48D93317139ADDaC8fb;
        }
        if (_chainId == 8453) {
            return 0x3A91A31cB3dC49b4db9Ce721F50a9D076c8D739B;
        }
        // No Chainalysis oracle configured for this chain (e.g. local/test chains): disables sanctions screening
        return address(0);
    }
}
