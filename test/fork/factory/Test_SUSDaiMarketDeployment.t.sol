// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { TokenInfo, TokenType } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { Test } from "../../../lib/forge-std/src/Test.sol";
import { IERC4626 } from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { DayMarketRegistry } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketRegistry.sol";
import { DayMarketConfig } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketTypes.sol";
import { DeployMarketComponent } from "../../../script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol";
import { ADMIN_ENTRY_POINT_ROLE, ADMIN_FACTORY_ROLE, SYNC_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { BaseDeploymentTemplate } from "../../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { AggregatorV3Interface } from "../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { NAV_UNIT } from "../../../src/libraries/Units.sol";
import { ERC4626SharePriceOracle } from "../../../src/oracle/ERC4626SharePriceOracle.sol";
import { FactoryScaffold } from "../../utils/FactoryScaffold.sol";
import { TemplateScaffold } from "../../utils/TemplateScaffold.sol";

/// @title Test_SUSDaiMarketDeployment
/// @notice Fork test for the sUSDai market config — the family's FIRST ARBITRUM market: sUSDai (18-decimal ERC4626
///         over USDai) priced through `convertToAssets` (sUSDai's `previewRedeem` reverts on-chain) composed with the
///         $1 identity recipe (a zero feed address, resolved by the script's oracle phase into the always-fresh
///         constant-1.0 feed), whose LPT pool quotes in Arbitrum frxUSD as a plain STANDARD stablecoin leg. Exercises
///         the Arbitrum venue mappings (Gyro E-CLP + E-CLP LP oracle factories) end-to-end.
/// @dev Requires an Arbitrum fork. FAILS (env not found) when `ARBITRUM_RPC_URL` is unset, instead of silently passing.
contract Test_SUSDaiMarketDeployment is Test {
    uint256 internal constant FORK_BLOCK = 492_500_000;
    address internal constant GYRO_ECLP_POOL_FACTORY = 0xe31715e75207acC8bfadd96902FF522058928479;

    /// @dev The market's real Arbitrum contract set, cross-checked on-chain in setUp so a config drift fails loudly
    address internal constant SUSDAI = 0x0B2b2B2076d95dda7817e785989fE353fe955ef9; // ERC4626 over USDai, 18 decimals
    address internal constant FRXUSD_ARB = 0x80Eede496655FB9047dd39d9f418d5483ED600df; // Frax's OFT frxUSD, 18 decimals

    RoycoAccessManager internal am;
    RoycoFactory internal factory;
    DayMarketRegistry internal registry;
    DeployMarketComponent internal marketBuilder;
    RoycoDayBalancerV3MarketDeploymentTemplate internal template;
    IRoycoDayEntryPoint internal entryPoint;
    RoycoMarketSyncer internal syncer;
    address internal roycoBlacklist;

    address internal FACTORY_ADMIN = makeAddr("FACTORY_ADMIN");
    address internal DEPLOYER = makeAddr("DEPLOYER");

    /// @dev A stable SEED, not a final id: `buildMarketParams` mines the id that sorts the ST proxy below frxUSD
    bytes32 internal constant MARKET_ID_SEED = keccak256("SUSDAI_TEST_SEED");

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), FORK_BLOCK);

        am = new RoycoAccessManager(address(this));
        (factory,, entryPoint, syncer) = FactoryScaffold.deployFactory(am, keccak256("FACTORY_PROXY"));
        roycoBlacklist = FactoryScaffold.deployBlacklist(am);

        am.grantRole(ADMIN_FACTORY_ROLE, FACTORY_ADMIN, 0);

        bytes4[] memory entryPointSelectors = new bytes4[](1);
        entryPointSelectors[0] = IRoycoDayEntryPoint.modifyTrancheConfigs.selector;
        am.setTargetFunctionRole(address(entryPoint), entryPointSelectors, ADMIN_ENTRY_POINT_ROLE);
        bytes4[] memory syncerSelectors = new bytes4[](1);
        syncerSelectors[0] = RoycoMarketSyncer.addMarketKernels.selector;
        am.setTargetFunctionRole(address(syncer), syncerSelectors, SYNC_ROLE);

        // The scaffold resolves the ARBITRUM venue factories from the chain id — the mapping under test here
        TemplateScaffold.Result memory scaffold = TemplateScaffold.standUp(am, factory, roycoBlacklist);
        registry = scaffold.registry;
        marketBuilder = scaffold.market;
        template = scaffold.template;

        bytes4[] memory ydmSelectors = new bytes4[](1);
        ydmSelectors[0] = BaseDeploymentTemplate.setYieldDistributionModels.selector;
        am.setTargetFunctionRole(address(template), ydmSelectors, ADMIN_FACTORY_ROLE);
        am.grantRole(ADMIN_FACTORY_ROLE, address(scaffold.ydms), 0);
        scaffold.ydms.registerModels();

        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));

        // Pin the config's external addresses against the live chain, so an address typo in the config file fails
        // here with a named reason instead of deep inside a deployment
        DayMarketConfig memory cfg = registry.getDayMarketConfig("sUSDai");
        assertEq(cfg.collateralAsset, SUSDAI, "config collateral != sUSDai");
        assertEq(cfg.pool.quoteAsset, FRXUSD_ARB, "config quote != Arbitrum frxUSD");
        assertEq(cfg.pool.quoteAssetRateProvider, address(0), "a plain-stable quote must carry no rate provider");
        assertGt(IERC4626(SUSDAI).convertToAssets(1e18), 1e18, "sUSDai share price must be live and above par");
    }

    // ─── helpers ───

    /// @dev The registry config with the collateral oracle deployed through the SCRIPT'S OWN oracle phase — which
    ///      also resolves the zero feed address into the constant-1.0 identity feed — and the frxUSD seed dealt
    function _marketConfig() internal returns (DayMarketConfig memory cfg) {
        cfg = registry.getDayMarketConfig("sUSDai");
        cfg.oracle.deployed = marketBuilder.deployCollateralOracle(cfg, MARKET_ID_SEED);
        deal(cfg.pool.quoteAsset, DEPLOYER, cfg.poolInitialization.quoteAmount);
        vm.prank(DEPLOYER);
        IERC20(cfg.pool.quoteAsset).approve(address(template), cfg.poolInitialization.quoteAmount);
    }

    function _deploy() internal returns (IRoycoProtocolTemplate.DeploymentResult memory) {
        bytes memory p = abi.encode(marketBuilder.buildMarketParams(_marketConfig(), MARKET_ID_SEED, address(factory), DEPLOYER));
        vm.prank(DEPLOYER);
        return factory.executeMarketDeployment(address(template), p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT WIRING (the Arbitrum + identity-feed deltas)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The frxUSD quote leg registers STANDARD with no rate provider while the senior leg stays
    ///         kernel-rate-provided — the first pool the family opens outside Ethereum mainnet
    function test_ExecuteMarketDeployment_QuoteLegIsStandardArbitrumFrxUsd() external {
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();
        address pool = IRoycoDayKernel(r.kernel).lptAsset();

        IVault vault = IVault(address(GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY).getVault()));
        (IERC20[] memory tokens, TokenInfo[] memory info,,) = vault.getPoolTokenInfo(pool);
        assertEq(address(tokens[0]), r.seniorTranche, "senior leg must be token0");
        assertEq(address(tokens[1]), FRXUSD_ARB, "quote leg must be Arbitrum frxUSD");
        assertTrue(info[0].tokenType == TokenType.WITH_RATE && address(info[0].rateProvider) == r.kernel, "senior leg not kernel-rated");
        assertTrue(info[1].tokenType == TokenType.STANDARD, "a plain-stable quote leg must register STANDARD");
        assertEq(address(info[1].rateProvider), address(0), "a STANDARD quote leg must carry no rate provider");
        assertFalse(info[0].paysYieldFees || info[1].paysYieldFees, "no leg may pay Balancer yield fees");
    }

    /// @notice The identity recipe composes exactly: the script's oracle phase resolves the zero feed into the
    ///         constant-1.0 feed, so the composed NAV equals the raw `convertToAssets` share price — and the feed's
    ///         `updatedAt == block.timestamp` keeps the Chainlink staleness gate permanently satisfied
    function test_ExecuteMarketDeployment_IdentityFeedPricesShareAtConvertToAssets() external {
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();

        IRoycoDayKernel kernel = IRoycoDayKernel(r.kernel);
        assertEq(kernel.collateralAsset(), SUSDAI, "kernel collateral != sUSDai");
        assertEq(kernel.quoteAsset(), FRXUSD_ARB, "kernel quote != Arbitrum frxUSD");

        ERC4626SharePriceOracle oracle = ERC4626SharePriceOracle(kernel.getCollateralAssetOracle());
        assertEq(oracle.COLLATERAL_ASSET(), SUSDAI, "oracle collateral != market collateral");

        // The identity feed marks USDai at exactly 1.0, always fresh
        AggregatorV3Interface feed = AggregatorV3Interface(address(oracle.ORACLE()));
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(uint256(answer), 1e18, "the identity feed must answer exactly 1.0");
        assertEq(updatedAt, block.timestamp, "the identity feed must always read fresh");

        (NAV_UNIT price,) = oracle.getPrice();
        assertEq(NAV_UNIT.unwrap(price), IERC4626(SUSDAI).convertToAssets(1e18), "composed NAV must equal the raw share price");
    }

    /// @notice The sUSDai economics land on-chain: the 7-day fixed term, and the LPT liquidity premium disabled
    function test_ExecuteMarketDeployment_SUsdaiEconomicsConfigured() external {
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = IRoycoDayAccountant(r.accountant).getState();
        assertEq(a.fixedTermDurationSeconds, 7 days, "sUSDai fixed term");
        assertEq(a.maxLPTYieldShareWAD, 0, "LPT liquidity premium must be disabled");
        assertEq(IRoycoDayKernel(r.kernel).getState().stSelfLiquidationBonusWAD, 0.01e18, "sUSDai self-liquidation bonus");
    }

    /// @notice The 18-decimal frxUSD genesis seed lands: quote-only depth, dead-share lock parked, remainder held
    function test_ExecuteMarketDeployment_GenesisSeedInArbitrumFrxUsd() external {
        DayMarketConfig memory cfg = registry.getDayMarketConfig("sUSDai");
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();
        address pool = IRoycoDayKernel(r.kernel).lptAsset();

        IVault vault = IVault(address(GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY).getVault()));
        (,, uint256[] memory balances,) = vault.getPoolTokenInfo(pool);
        assertEq(balances[0], 0, "quote-only seed must leave the senior leg empty");
        assertEq(balances[1], cfg.poolInitialization.quoteAmount, "quote leg must hold the full frxUSD seed");
        assertEq(IERC20(r.liquidityProviderTranche).balanceOf(template.DEAD_ADDRESS()), template.DEAD_SHARES(), "dead-share lock must be parked");
    }
}
