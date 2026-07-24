// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DeployScript } from "../../../script/Deploy.s.sol";
import { TAG_ST_PROXY } from "../../../src/factory/templates/base/Constants.sol";
import { CREATE3 } from "../../../lib/solady/src/utils/CREATE3.sol";
import { Test } from "lib/forge-std/src/Test.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";

/**
 * @title Test_MineMarketId
 * @notice Guards that the marketIds baked into MarketDeploymentConfig still place each market's senior-tranche CREATE3
 *         proxy below the quote asset, so the ST is pool token0 (the invariant the deployment path asserts). The local
 *         factory is also exercised by the real deploy suites; the mainnet factory is otherwise unverified until
 *         production, so this is the only pre-flight check on its mined id. Re-mine with script/mine-market-id (or the
 *         `test_MineForConfigFactories` helper below) if a factory changes — e.g. after the singleton salts change.
 */
contract Test_MineMarketId is Test {
    DeployScript internal deployScript;

    address internal constant DETERMINISTIC_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant PROD_DEPLOYER = 0x35518D5E1fD8105FC325c5c171c329c3B10b254c;
    // snUSD's quote leg (USDC mainnet), the address the senior-tranche proxy must sort below.
    address internal constant QUOTE_ASSET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    string internal constant MARKET_NAME = "snUSD";

    function setUp() public {
        // Fork so USDC has code (DeployScript's config init reads the quote asset's symbol()).
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envOr("FORK_BLOCK", uint256(25_400_000)));
        deployScript = new DeployScript();
    }

    /// @dev CREATE2 address under the canonical deterministic deployer.
    function _c2(bytes32 _salt, bytes memory _code) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DETERMINISTIC_CREATE2_FACTORY, _salt, keccak256(_code))))));
    }

    /// @dev The production ("_PROD" salts) factory proxy a given deployer stands up. Mirrors
    ///      DeployScript._deployAccessManagerAndFactory; the whole test suite runs on the production config.
    function _predictFactory(address _deployer) internal pure returns (address) {
        address am = _c2(keccak256("ROYCO_ACCESS_MANAGER_PROD"), abi.encodePacked(type(AccessManager).creationCode, abi.encode(_deployer)));
        address impl = _c2(keccak256("ROYCO_FACTORY_IMPLEMENTATION_PROD"), type(RoycoFactory).creationCode);
        bytes memory proxyCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, abi.encodeCall(RoycoFactory.initialize, (am))));
        return _c2(keccak256("ROYCO_FACTORY_PROXY_PROD"), proxyCode);
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
        _assertSeniorTrancheFirst(_predictFactory(PROD_DEPLOYER));
    }

    function test_ConfiguredMarketId_Local_PutsSeniorTrancheFirst() public {
        _assertSeniorTrancheFirst(_predictFactory(vm.createWallet("DEPLOYER").addr));
    }
}
