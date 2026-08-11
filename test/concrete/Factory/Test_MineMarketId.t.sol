// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DayMarketRegistry } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketRegistry.sol";
import { DayMarketConfig } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketTypes.sol";
import { DeployMarketComponent } from "../../../script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol";
import { MarketUpstream } from "../../../script/config/DeploymentTypes.sol";
import { RoycoDeterministic } from "../../../script/deploy/utils/RoycoDeterministic.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { Test } from "lib/forge-std/src/Test.sol";

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
    DayMarketRegistry internal registry;
    DeployMarketComponent internal marketBuilder;

    address internal constant PROD_DEPLOYER = 0x35518D5E1fD8105FC325c5c171c329c3B10b254c;
    // snUSD's quote leg (USDC mainnet), the address the senior-tranche proxy must sort below.
    address internal constant QUOTE_ASSET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant PROTOCOL_FEE_RECIPIENT = 0x05ea95aE815809D77153Ed3500Ad6d936712b639;
    string internal constant MARKET_NAME = "snUSD";

    function setUp() public {
        // Fork so USDC has code (the registry's config init reads the quote asset's symbol()).
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envOr("FORK_BLOCK", uint256(25_400_000)));
        registry = new DayMarketRegistry();
        marketBuilder = new DeployMarketComponent(
            MarketUpstream({ accessManager: address(0), factory: address(0), entryPoint: address(0), marketSyncer: address(0), template: address(0) })
        );
    }

    /// @dev The production ("_PROD" salts) factory proxy a given deployer stands up — the SAME library derivation
    ///      the deploy pipeline and the config registry use, so this guard can no longer drift from either.
    function _predictFactory(address _deployer) internal pure returns (address) {
        return RoycoDeterministic.predictFactoryProxy(_deployer, false);
    }

    /// @dev The senior-tranche CREATE3 proxy address the template will land on for these exact params and deployer.
    function _predictSeniorTranche(
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory _params,
        address _factory,
        address _deployer
    )
        internal
        pure
        returns (address)
    {
        return RoycoDeterministic.predictSeniorTranche(_params, _factory, _deployer);
    }

    /// @dev Builds the market's real params for `_deployer` (which mines the id) and asserts the ordering invariant
    function _assertMinedIdPutsSeniorTrancheFirst(address _deployer) internal view {
        address factory = _predictFactory(_deployer);
        DayMarketConfig memory config = registry.getDayMarketConfig(MARKET_NAME);
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory params =
            marketBuilder.buildMarketParams(config, registry.getMarketId(MARKET_NAME, factory), factory, _deployer);

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
        DayMarketConfig memory config = registry.getDayMarketConfig(MARKET_NAME);
        bytes32 seed = registry.getMarketId(MARKET_NAME, prodFactory);

        // Same factory, same seed, same config: only the deploying account differs
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory prodParams = marketBuilder.buildMarketParams(config, seed, prodFactory, PROD_DEPLOYER);
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory localParams = marketBuilder.buildMarketParams(config, seed, prodFactory, localDeployer);

        assertTrue(
            _predictSeniorTranche(prodParams, prodFactory, PROD_DEPLOYER) != _predictSeniorTranche(localParams, prodFactory, localDeployer),
            "two deployers must not land on the same senior tranche"
        );
    }
}
