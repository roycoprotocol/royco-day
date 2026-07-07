// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice ERC1967 proxy deployable without init data so tests can call initialize as a separate, observable external call
contract UninitializedERC1967Proxy is ERC1967Proxy {
    constructor(address _implementation) ERC1967Proxy(_implementation, "") { }

    function _unsafeAllowUninitialized() internal pure override(ERC1967Proxy) returns (bool) {
        return true;
    }
}
