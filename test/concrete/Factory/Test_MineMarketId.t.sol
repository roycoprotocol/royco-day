// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { CREATE3 } from "../../../lib/solady/src/utils/CREATE3.sol";
import { Test } from "lib/forge-std/src/Test.sol";
import { DeployScript } from "../../../script/Deploy.s.sol";
import { MarketConfig } from "../../../script/config/DeploymentTypes.sol";
import { RoycoCreate3Deployer } from "../../../src/factory/RoycoCreate3Deployer.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { TAG_ST_PROXY } from "../../../src/factory/templates/base/Constants.sol";

/**
 * @title Test_MineMarketId
 * @notice Guards that the market id `_buildMarketParams` mines places the market's senior-tranche CREATE3 proxy below
 *         the quote asset, so the senior leg registers as pool token0 — the invariant the deployment path asserts and
 *         reverts `SENIOR_TRANCHE_NOT_FIRST_POOL_TOKEN` on
 * @dev There is no longer a baked market id to pre-verify. Every component salt hashes the WHOLE params struct plus
 *      the deploying account, so the id is only computable once the params are final: the configured value is a seed
 *      the miner searches on top of, and this suite pins that the search actually holds the invariant. It also pins
 *      that the miner mirrors the template's salt derivation — if the two ever drift, mining yields an id that fails
 *      the ordering check and every deployment reverts
 */
contract Test_MineMarketId is Test {
    DeployScript internal deployScript;

    address internal constant DETERMINISTIC_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant PROD_DEPLOYER = 0x35518D5E1fD8105FC325c5c171c329c3B10b254c;
    // snUSD's quote leg (USDC mainnet), the address the senior-tranche proxy must sort below.
    address internal constant QUOTE_ASSET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant PROTOCOL_FEE_RECIPIENT = 0x05ea95aE815809D77153Ed3500Ad6d936712b639;
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
        // The proxy is a CREATE3 address off the protocol's CREATE3 deployer, so it depends on the salt alone
        address create3Deployer = _c2(keccak256("ROYCO_CREATE3_DEPLOYER_PROD"), type(RoycoCreate3Deployer).creationCode);
        return CREATE3.predictDeterministicAddress(keccak256(abi.encode(_deployer, keccak256("ROYCO_FACTORY_PROXY_PROD"))), create3Deployer);
    }

    /// @dev The senior-tranche CREATE3 proxy address the template will land on for these exact params and deployer.
    ///      Mirrors RoycoDayBalancerV3MarketDeploymentTemplate.deployMarket + BaseDeploymentTemplate._marketComponentSalt
    function _predictSeniorTranche(
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory _params,
        address _factory,
        address _deployer
    )
        internal
        pure
        returns (address)
    {
        bytes32 baseSalt = keccak256(abi.encode(_params, _deployer));
        return CREATE3.predictDeterministicAddress(keccak256(abi.encodePacked("ROYCO_MARKET_", baseSalt, TAG_ST_PROXY)), _factory);
    }

    /// @dev Builds the market's real params for `_deployer` (which mines the id) and asserts the ordering invariant
    function _assertMinedIdPutsSeniorTrancheFirst(address _deployer) internal view {
        address factory = _predictFactory(_deployer);
        MarketConfig memory config = deployScript.getMarketConfig(MARKET_NAME);
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory params =
            deployScript.buildMarketParams(config, deployScript.getMarketId(MARKET_NAME, factory), factory, _deployer);

        assertEq(params.quoteAsset, QUOTE_ASSET, "the market's quote leg must be the asset the ordering is mined against");
        assertLt(
            uint160(_predictSeniorTranche(params, factory, _deployer)),
            uint160(QUOTE_ASSET),
            "the mined marketId does not place the senior tranche as pool token0"
        );
    }

    function test_MinedMarketId_Mainnet_PutsSeniorTrancheFirst() public view {
        _assertMinedIdPutsSeniorTrancheFirst(PROD_DEPLOYER);
    }

    function test_MinedMarketId_Local_PutsSeniorTrancheFirst() public {
        _assertMinedIdPutsSeniorTrancheFirst(vm.createWallet("DEPLOYER").addr);
    }

    /// @notice The deployer is mixed into the base salt, so the same config mined for two deployers lands on two
    ///         different senior tranches
    /// @dev The mined ids may well coincide — the search starts at nonce 0 for both and returns the first id that
    ///      satisfies the ordering. It is the derived ADDRESSES that the deployer separates, which is the property
    ///      that keeps two deployers from colliding on each other's CREATE3 salts
    function test_MinedMarketId_IsScopedToTheDeployer() public {
        address localDeployer = vm.createWallet("DEPLOYER").addr;
        address prodFactory = _predictFactory(PROD_DEPLOYER);
        MarketConfig memory config = deployScript.getMarketConfig(MARKET_NAME);
        bytes32 seed = deployScript.getMarketId(MARKET_NAME, prodFactory);

        // Same factory, same seed, same config: only the deploying account differs
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory prodParams =
            deployScript.buildMarketParams(config, seed, prodFactory, PROD_DEPLOYER);
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory localParams =
            deployScript.buildMarketParams(config, seed, prodFactory, localDeployer);

        assertTrue(
            _predictSeniorTranche(prodParams, prodFactory, PROD_DEPLOYER) != _predictSeniorTranche(localParams, prodFactory, localDeployer),
            "two deployers must not land on the same senior tranche"
        );
    }
}
