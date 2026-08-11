// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { TokenInfo, TokenType } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { Test } from "../../../lib/forge-std/src/Test.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { ERC4626SharePriceOracleParams } from "../../../script/config/DeploymentTypes.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { RoycoFactoryGatekeeper } from "../../../src/factory/RoycoFactoryGatekeeper.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { BaseDeploymentTemplate } from "../../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { ADMIN_ENTRY_POINT_ROLE, ADMIN_FACTORY_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { NAV_UNIT } from "../../../src/libraries/Units.sol";
import { ERC4626SharePriceOracle } from "../../../src/oracle/ERC4626SharePriceOracle.sol";
import { DayMarketRegistry } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketRegistry.sol";
import { DayMarketConfig } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketTypes.sol";
import { DeployMarketComponent } from "../../../script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol";
import { FactoryScaffold } from "../../utils/FactoryScaffold.sol";
import { TemplateScaffold } from "../../utils/TemplateScaffold.sol";

/// @title Test_SrRoyUsdcMarketDeployment
/// @notice Fork test for the srRoyUSDC market config: an srRoyUSDC (ERC4626 over USDC) senior/junior pair whose LPT
///         pool quotes in frxUSD — a plain stablecoin quote registered STANDARD with no rate provider. Covers the
///         deltas no other suite reaches: the STANDARD external-stable quote leg, an 18-decimal
///         quote seeding the genesis pool, and the LPT liquidity premium switched ON (nonzero minLiquidityWAD and
///         maxLPTYieldShareWAD, distinct V2 curves for JT and LPT).
/// @dev Modeled on Test_ChainlinkOracleMarketDeployment's direct-template pattern. Requires a mainnet fork. FAILS
///      (env not found) when `MAINNET_RPC_URL` is unset, instead of silently passing.
contract Test_SrRoyUsdcMarketDeployment is Test {
    uint256 internal constant FORK_BLOCK = 25_400_000;
    address internal constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;

    /// @dev The market's real mainnet contract set, cross-checked on-chain in setUp so a config drift fails loudly
    address internal constant SRROYUSDC_VAULT = 0xcD9f5907F92818bC06c9Ad70217f089E190d2a32; // ERC4626 over USDC
    address internal constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29; // 18-decimals, plain stablecoin quote
    address internal constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // Chainlink, 8 decimals

    RoycoAccessManager internal am;
    RoycoFactoryGatekeeper internal gatekeeper;
    RoycoFactory internal factory;
    DayMarketRegistry internal registry;
    DeployMarketComponent internal marketBuilder;
    RoycoDayBalancerV3MarketDeploymentTemplate internal template;
    IRoycoDayEntryPoint internal entryPoint;
    RoycoMarketSyncer internal syncer;
    address internal roycoBlacklist;

    address internal FACTORY_ADMIN = makeAddr("FACTORY_ADMIN");
    address internal DEPLOYER = makeAddr("DEPLOYER");

    /// @dev A stable SEED, not a final id: `buildMarketParams` mines the id that sorts the ST proxy below frxUSD on
    ///      top of it, against the full params and the deploying account
    bytes32 internal constant MARKET_ID_SEED = keccak256("SRROYUSDC_TEST_SEED");

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc, FORK_BLOCK);

        am = new RoycoAccessManager(address(this));
        (factory, gatekeeper, entryPoint, syncer) = FactoryScaffold.deployFactory(am, keccak256("FACTORY_PROXY"));
        roycoBlacklist = FactoryScaffold.deployBlacklist(address(this));

        am.grantRole(ADMIN_FACTORY_ROLE, FACTORY_ADMIN, 0);

        bytes4[] memory entryPointSelectors = new bytes4[](1);
        entryPointSelectors[0] = IRoycoDayEntryPoint.modifyTrancheConfigs.selector;
        am.setTargetFunctionRole(address(entryPoint), entryPointSelectors, ADMIN_ENTRY_POINT_ROLE);
        bytes4[] memory syncerSelectors = new bytes4[](1);
        syncerSelectors[0] = RoycoMarketSyncer.addMarketKernels.selector;
        am.setTargetFunctionRole(address(syncer), syncerSelectors, ADMIN_ENTRY_POINT_ROLE);

        TemplateScaffold.Result memory scaffold = TemplateScaffold.standUp(am, factory);
        registry = scaffold.registry;
        marketBuilder = scaffold.market;
        template = scaffold.template;

        bytes4[] memory ydmSelectors = new bytes4[](1);
        ydmSelectors[0] = BaseDeploymentTemplate.setYieldDistributionModels.selector;
        am.setTargetFunctionRole(address(template), ydmSelectors, ADMIN_FACTORY_ROLE);
        am.grantRole(ADMIN_FACTORY_ROLE, address(scaffold.ydms), 0);
        scaffold.ydms.registerModels();

        // Pin the config's external addresses against the live chain, so an address typo in the config file fails
        // here with a named reason instead of deep inside a deployment
        DayMarketConfig memory cfg = registry.getDayMarketConfig("srRoyUSDC");
        assertEq(cfg.collateralAsset, SRROYUSDC_VAULT, "config collateral != srRoyUSDC vault");
        assertEq(IERC4626(cfg.collateralAsset).asset(), IERC4626(SRROYUSDC_VAULT).asset(), "vault underlying drifted");
        assertEq(cfg.pool.quoteAsset, FRXUSD, "config quote != frxUSD");
        assertEq(cfg.pool.quoteAssetRateProvider, address(0), "a plain-stable quote must carry no rate provider");
    }

    // ─── helpers ───

    function _register() internal {
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));
    }

    /// @dev The config leaves the oracle unset for the `deploy()` flow to resolve; the direct-template path deploys
    ///      the ERC4626 share-price adapter itself: srRoyUSDC share -> USDC via convertToAssets, USDC -> NAV via the feed
    function _marketConfig() internal returns (DayMarketConfig memory cfg) {
        cfg = registry.getDayMarketConfig("srRoyUSDC");
        cfg.oracle.deployed = address(
            _newErc4626Oracle(cfg.collateralAsset, cfg.oracle.specificParams)
        );
        cfg.roycoBlacklist = roycoBlacklist;
        _fundPoolSeed(cfg);
    }

    /// @dev The genesis seed is pulled from the deployment caller: fund and approve the 18-decimal frxUSD quote leg
    function _fundPoolSeed(DayMarketConfig memory _cfg) internal {
        deal(_cfg.pool.quoteAsset, DEPLOYER, _cfg.poolInitialization.quoteAmount);
        vm.prank(DEPLOYER);
        IERC20(_cfg.pool.quoteAsset).approve(address(template), _cfg.poolInitialization.quoteAmount);
    }

    function _deploy() internal returns (IRoycoProtocolTemplate.DeploymentResult memory) {
        bytes memory p = abi.encode(marketBuilder.buildMarketParams(_marketConfig(), MARKET_ID_SEED, address(factory), DEPLOYER));
        vm.prank(DEPLOYER);
        return factory.executeMarketDeployment(address(template), p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT WIRING (the srRoyUSDC deltas)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The plain-stable quote leg registers STANDARD with no rate provider — frxUSD is the base unit, so
    ///         there is no redemption rate to scale by — while the senior leg stays kernel-rate-provided, and
    ///         neither leg pays Balancer yield fees per the template's pool policy
    function test_ExecuteMarketDeployment_QuoteLegIsStandard() external {
        _register();
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();
        address pool = IRoycoDayKernel(r.kernel).lptAsset();

        IVault vault = IVault(address(GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY).getVault()));
        (IERC20[] memory tokens, TokenInfo[] memory info,,) = vault.getPoolTokenInfo(pool);
        assertEq(tokens.length, 2, "pool token count");
        assertEq(address(tokens[0]), r.seniorTranche, "senior leg must be token0");
        assertEq(address(tokens[1]), FRXUSD, "quote leg must be frxUSD");

        assertTrue(info[0].tokenType == TokenType.WITH_RATE, "senior leg not WITH_RATE");
        assertEq(address(info[0].rateProvider), r.kernel, "senior rate provider != kernel");
        assertTrue(info[1].tokenType == TokenType.STANDARD, "a plain-stable quote leg must register STANDARD");
        assertEq(address(info[1].rateProvider), address(0), "a STANDARD quote leg must carry no rate provider");
        assertFalse(info[0].paysYieldFees, "senior leg must not pay Balancer yield fees");
        assertFalse(info[1].paysYieldFees, "quote leg must not pay Balancer yield fees");
    }

    /// @notice The kernel wires the market's real asset set — srRoyUSDC collateral, frxUSD quote — and the ERC4626
    ///         share-price oracle passes the collateral identity check and prices one share at a plausible USD value
    function test_ExecuteMarketDeployment_KernelAssetsAndOracle() external {
        _register();
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();

        IRoycoDayKernel kernel = IRoycoDayKernel(r.kernel);
        assertEq(kernel.collateralAsset(), SRROYUSDC_VAULT, "kernel collateral != srRoyUSDC vault");
        assertEq(kernel.quoteAsset(), FRXUSD, "kernel quote != frxUSD");

        address oracle = kernel.getCollateralAssetOracle();
        assertEq(ERC4626SharePriceOracle(oracle).COLLATERAL_ASSET(), SRROYUSDC_VAULT, "oracle collateral != market collateral");

        // One srRoyUSDC share is worth at least its USDC underlying (non-decreasing 4626 share price) and the
        // composed NAV must sit in a sane band around $1 — a decimals slip on the 6-dec vault would blow this bound
        (NAV_UNIT price,) = ERC4626SharePriceOracle(oracle).getPrice();
        assertGt(NAV_UNIT.unwrap(price), 0.95e18, "share NAV implausibly low");
        assertLt(NAV_UNIT.unwrap(price), 1.5e18, "share NAV implausibly high");
    }

    /// @notice The LPT liquidity premium is ON for this market: nonzero market-making floor and premium cap, and the
    ///         accountant carries two DISTINCT AdaptiveCurve_V2 instances for the JT and LPT
    function test_ExecuteMarketDeployment_LiquidityPremiumConfigured() external {
        _register();
        DayMarketConfig memory cfg = registry.getDayMarketConfig("srRoyUSDC");
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();

        IRoycoDayAccountant.RoycoDayAccountantState memory a = IRoycoDayAccountant(r.accountant).getState();
        assertEq(a.minLiquidityWAD, cfg.accountant.minLiquidityWAD, "minLiquidityWAD");
        assertEq(a.maxJTYieldShareWAD, cfg.accountant.maxJTYieldShareWAD, "maxJTYieldShareWAD");
        assertEq(a.maxLPTYieldShareWAD, cfg.accountant.maxLPTYieldShareWAD, "maxLPTYieldShareWAD");
        assertLe(uint256(a.maxJTYieldShareWAD) + a.maxLPTYieldShareWAD, 1e18, "caps must sum within the senior gain");
        assertTrue(a.jtYDM != a.lptYDM, "JT and LPT must hold distinct model instances");
        assertEq(a.jtYDM, r.ydm, "accountant JT model != registry instance");
        assertEq(a.lptYDM, r.lptYdm, "accountant LPT model != registry instance");
    }

    /// @notice The 18-decimal frxUSD genesis seed lands: the pool opens with quote-only depth, the dead-share lock is
    ///         parked, and the deployer holds the remainder — the exact flow a 6-decimals-assumption seed would break
    function test_ExecuteMarketDeployment_GenesisSeedWithEighteenDecimalQuote() external {
        _register();
        DayMarketConfig memory cfg = registry.getDayMarketConfig("srRoyUSDC");
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();
        address pool = IRoycoDayKernel(r.kernel).lptAsset();

        IVault vault = IVault(address(GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY).getVault()));
        (,, uint256[] memory balances,) = vault.getPoolTokenInfo(pool);
        assertEq(balances[0], 0, "quote-only seed must leave the senior leg empty");
        assertEq(balances[1], cfg.poolInitialization.quoteAmount, "quote leg must hold the full seed");

        uint256 deadShares = template.DEAD_SHARES();
        assertEq(IERC20(r.liquidityProviderTranche).balanceOf(template.DEAD_ADDRESS()), deadShares, "dead-share lock must be parked");
        assertGt(IERC20(r.liquidityProviderTranche).balanceOf(DEPLOYER), 0, "deployer must hold the remaining genesis shares");
        assertEq(
            IERC20(r.liquidityProviderTranche).totalSupply(),
            IERC20(r.liquidityProviderTranche).balanceOf(template.DEAD_ADDRESS()) + IERC20(r.liquidityProviderTranche).balanceOf(DEPLOYER),
            "genesis supply must be exactly lock + deployer remainder"
        );
    }

    /// @notice A dust seed — the exact bug this config shipped with, `1e6` wei of an 18-decimal quote — kills the
    ///         whole deployment atomically rather than opening a near-unseeded market
    /// @dev The observed revert is a `SafeCastOverflowedIntToUint` from inside Gyro's E-CLP invariant math, which
    ///      goes negative on a dust-sized deposit BEFORE the template's own `INSUFFICIENT_GENESIS_SHARES` check can
    ///      run — i.e. the original config would have failed with an unnamed Balancer error, not a Royco one. The
    ///      property pinned here is that it fails at all, and unwinds
    function test_RevertIf_SeedIsDustAgainstTheQuoteDecimals() external {
        _register();
        DayMarketConfig memory cfg = _marketConfig();
        cfg.poolInitialization.quoteAmount = 1e6; // "$1" under a 6-decimals assumption; ~1e-12 frxUSD in reality
        _fundPoolSeed(cfg);

        bytes memory p = abi.encode(marketBuilder.buildMarketParams(cfg, MARKET_ID_SEED, address(factory), DEPLOYER));
        vm.prank(DEPLOYER);
        vm.expectRevert();
        factory.executeMarketDeployment(address(template), p);
    }
    /// @dev Deploys the config's ERC4626 share-price adapter with its per-hop staleness immutable, as the script does
    function _newErc4626Oracle(address _collateral, bytes memory _oracleParams) internal returns (ERC4626SharePriceOracle) {
        ERC4626SharePriceOracleParams memory op = abi.decode(_oracleParams, (ERC4626SharePriceOracleParams));
        return new ERC4626SharePriceOracle(
            _collateral,
            op.queryMode,
            op.baseAssetToNavAssetFeed,
            op.minDeviationWAD,
            op.lastUpdate,
            op.chainlinkOracleStalenessThresholdSeconds,
            op.vaultSharePriceStalenessThresholdSeconds
        );
    }

}
