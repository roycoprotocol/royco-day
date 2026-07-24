// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockThreeTokenVaultShim
 * @notice Minimal vault shim registering a pool with an arbitrary token list, the only way to reach the LPT
 *         quoter constructor's POOL_MUST_HAVE_TWO_TOKENS guard, since MockBalancerVault's registry is
 *         structurally two-token
 */
contract MockThreeTokenVaultShim {
    /// @dev The token list this shim reports for every pool
    IERC20[] internal _tokens;

    /// @notice Pins the token list this shim reports
    /// @param _poolTokens The tokens to report from getPoolTokens
    constructor(IERC20[] memory _poolTokens) {
        for (uint256 i; i < _poolTokens.length; ++i) {
            _tokens.push(_poolTokens[i]);
        }
    }

    /// @notice Reports every pool as registered
    function isPoolRegistered(address) external pure returns (bool) {
        return true;
    }

    /// @notice Reports the pinned token list for every pool
    function getPoolTokens(address) external view returns (IERC20[] memory) {
        return _tokens;
    }
}
