// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DeployScript } from "../../../script/Deploy.s.sol";
import { TAG_ST_PROXY } from "../../../src/factory/templates/base/Constants.sol";
import { CREATE3 } from "../../../lib/solady/src/utils/CREATE3.sol";
import { Test } from "lib/forge-std/src/Test.sol";

/**
 * @title Test_MineMarketId
 * @notice Guards that the marketIds baked into MarketDeploymentConfig still place each market's senior-tranche CREATE3
 *         proxy below the quote asset, so the ST is pool token0 (the invariant the deployment path asserts). The local
 *         factory is also exercised by the real deploy suites; the mainnet factory is otherwise unverified until
 *         production, so this is the only pre-flight check on its mined id. Re-mine with script/mine-market-id if a
 *         factory changes.
 */
contract Test_MineMarketId is Test {
    DeployScript internal deployScript;

    // The factory proxy addresses the config keys its mined marketIds against (mirror MarketDeploymentConfig).
    address internal constant MAINNET_FACTORY = 0x76fF747399Ed12F0B631323d6d4c6E1b66cB7c89;
    address internal constant LOCAL_FACTORY = 0x87F4fccE54F4D03De715A0C6fcd28b7Ea24664d1;
    // snUSD's quote leg (USDC mainnet), the address the senior-tranche proxy must sort below.
    address internal constant QUOTE_ASSET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    string internal constant MARKET_NAME = "snUSD";

    function setUp() public {
        // Fork so USDC has code (DeployScript's config init reads the quote asset's symbol()).
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envOr("FORK_BLOCK", uint256(25_400_000)));
        deployScript = new DeployScript();
    }

    /// @dev The senior-tranche CREATE3 proxy address for a marketId under `_factory`.
    function _predictSeniorTranche(address _factory, bytes32 _marketId) internal pure returns (address) {
        return CREATE3.predictDeterministicAddress(keccak256(abi.encodePacked("ROYCO_MARKET_", _marketId, TAG_ST_PROXY)), _factory);
    }

    function _assertSeniorTrancheFirst(address _factory) internal view {
        bytes32 id = deployScript.getMarketId(MARKET_NAME, _factory);
        assertLt(uint160(_predictSeniorTranche(_factory, id)), uint160(QUOTE_ASSET), "configured marketId does not place ST as token0");
    }

    function test_ConfiguredMarketId_Mainnet_PutsSeniorTrancheFirst() public view {
        _assertSeniorTrancheFirst(MAINNET_FACTORY);
    }

    function test_ConfiguredMarketId_Local_PutsSeniorTrancheFirst() public view {
        _assertSeniorTrancheFirst(LOCAL_FACTORY);
    }
}
