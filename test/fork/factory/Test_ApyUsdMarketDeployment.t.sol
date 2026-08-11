// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRateProvider } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { TokenInfo, TokenType } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { Test } from "../../../lib/forge-std/src/Test.sol";
import { IERC4626 } from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { ERC4626SharePriceOracleParams } from "../../../script/config/DeploymentTypes.sol";
import { ADMIN_ENTRY_POINT_ROLE, ADMIN_FACTORY_ROLE, JT_LP_ROLE, ST_LP_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { RoycoFactoryGatekeeper } from "../../../src/factory/RoycoFactoryGatekeeper.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { BaseDeploymentTemplate } from "../../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { AggregatorV3Interface } from "../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../../src/libraries/Units.sol";
import { ERC4626SharePriceOracle } from "../../../src/oracle/ERC4626SharePriceOracle.sol";
import { DayMarketRegistry } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketRegistry.sol";
import { DayMarketConfig } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketTypes.sol";
import { DeployMarketComponent } from "../../../script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol";
import { FactoryScaffold } from "../../utils/FactoryScaffold.sol";
import { TemplateScaffold } from "../../utils/TemplateScaffold.sol";

/// @title Test_ApyUsdMarketDeployment
/// @notice Fork test for the APYX (apyUSD) market config: an 18-decimal apyUSD (ERC4626 over apxUSD) collateral
///         behind the share-price oracle composed with the 18-DECIMAL Chainlink apxUSD/USD exchange-rate feed — every
///         other market's Chainlink leg is 8 decimals — whose LPT pool quotes in the srRoyUSDC senior tranche with
///         the srRoyUSDC kernel as the leg's rate provider. Also pins the APYX economics no other config carries: a
///         30-day fixed term and a ZERO senior self-liquidation bonus.
/// @dev The config bakes the live test-environment srRoyUSDC addresses, which do not exist at this fork block, so
///      setUp deploys the srRoyUSDC market from its own config first and points apyUSD's quote leg at it — the same
///      composition the production deployment performs, executed end-to-end. Requires a mainnet fork. FAILS (env not
///      found) when `MAINNET_RPC_URL` is unset, instead of silently passing.
contract Test_ApyUsdMarketDeployment is Test {
    using Math for uint256;

    uint256 internal constant FORK_BLOCK = 25_400_000;
    address internal constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;

    /// @dev The market's real mainnet contract set, cross-checked on-chain in setUp so a config drift fails loudly
    address internal constant APYUSD_VAULT = 0x38EEb52F0771140d10c4E9A9a72349A329Fe8a6A; // ERC4626 over apxUSD, 18 decimals
    address internal constant APXUSD_USD_FEED = 0x651b101f72F82630cf59c68E6EE4305aFBd3B1F5; // Chainlink exchange rate, 18 decimals

    /// @dev The upstream market's collateral, funding the deployer's senior-share mint
    address internal constant SRROYUSDC_VAULT = 0xcD9f5907F92818bC06c9Ad70217f089E190d2a32;

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

    /// @dev The srRoyUSDC market this scaffold stands up as the quote-side dependency
    address internal upstreamSt;
    address internal upstreamJt;
    address internal upstreamKernel;

    /// @dev Stable SEEDS, not final ids: `buildMarketParams` mines each id so the market's ST proxy sorts below its
    ///      quote asset, against the full params and the deploying account
    bytes32 internal constant SRROYUSDC_MARKET_ID_SEED = keccak256("SRROYUSDC_UPSTREAM_SEED");
    bytes32 internal constant APYUSD_MARKET_ID_SEED = keccak256("APYUSD_TEST_SEED");

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
        // Both markets run AdaptiveCurve_V2, so one registration serves the upstream and the apyUSD deployment
        am.grantRole(ADMIN_FACTORY_ROLE, address(scaffold.ydms), 0);
        scaffold.ydms.registerModels();

        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));

        // Pin the APYX config's external addresses against the live chain, so an address typo in the config file
        // fails here with a named reason instead of deep inside a deployment
        DayMarketConfig memory cfg = registry.getDayMarketConfig("APYX");
        assertEq(cfg.collateralAsset, APYUSD_VAULT, "config collateral != apyUSD vault");
        assertGt(IERC4626(APYUSD_VAULT).convertToAssets(1e18), 0, "apyUSD share price must be live");
        ERC4626SharePriceOracleParams memory p = abi.decode(cfg.oracle.specificParams, (ERC4626SharePriceOracleParams));
        assertEq(p.baseAssetToNavAssetFeed, APXUSD_USD_FEED, "config feed != Chainlink apxUSD/USD");
        assertEq(AggregatorV3Interface(APXUSD_USD_FEED).decimals(), 18, "the apxUSD/USD feed is expected to be 18 decimals");

        // Stand up the quote-side dependency: the srRoyUSDC market, then real senior shares for the deployer
        _deployUpstreamSrRoyUsdc();
        _mintUpstreamSeniorShares();
    }

    // ─── upstream (srRoyUSDC) helpers ───

    /// @dev Deploys the srRoyUSDC market from its own config, exactly as Test_SrRoyUsdcMarketDeployment does: the
    ///      ERC4626 share-price oracle is deployed directly and the 18-decimal frxUSD genesis seed is dealt
    function _deployUpstreamSrRoyUsdc() internal {
        DayMarketConfig memory cfg = registry.getDayMarketConfig("srRoyUSDC");
        cfg.oracle.deployed = address(
            _newErc4626Oracle(cfg.collateralAsset, cfg.oracle.specificParams)
        );
        cfg.roycoBlacklist = roycoBlacklist;
        deal(cfg.pool.quoteAsset, DEPLOYER, cfg.poolInitialization.quoteAmount);
        vm.prank(DEPLOYER);
        IERC20(cfg.pool.quoteAsset).approve(address(template), cfg.poolInitialization.quoteAmount);

        bytes memory params = abi.encode(marketBuilder.buildMarketParams(cfg, SRROYUSDC_MARKET_ID_SEED, address(factory), DEPLOYER));
        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), params);
        upstreamSt = r.seniorTranche;
        upstreamJt = r.juniorTranche;
        upstreamKernel = r.kernel;
    }

    /// @dev Mints REAL upstream senior shares to the deployer through the tranches themselves: junior first, so the
    ///      20% coverage requirement opens senior capacity, then the senior deposit that funds the apyUSD genesis
    ///      seed. The senior mint stays small enough that half its NAV fits the upstream market's 50% market-making
    ///      floor against its ~$1 genesis pool depth, while still covering the ST-share seed
    function _mintUpstreamSeniorShares() internal {
        am.grantRole(JT_LP_ROLE, DEPLOYER, 0);
        am.grantRole(ST_LP_ROLE, DEPLOYER, 0);

        uint256 jtAssets = 10e6;
        uint256 stAssets = 1.5e6;
        deal(SRROYUSDC_VAULT, DEPLOYER, jtAssets + stAssets);

        vm.startPrank(DEPLOYER);
        IERC20(SRROYUSDC_VAULT).approve(upstreamJt, jtAssets);
        IRoycoVaultTranche(upstreamJt).deposit(TRANCHE_UNIT.wrap(jtAssets), DEPLOYER);
        IERC20(SRROYUSDC_VAULT).approve(upstreamSt, stAssets);
        IRoycoVaultTranche(upstreamSt).deposit(TRANCHE_UNIT.wrap(stAssets), DEPLOYER);
        vm.stopPrank();
    }

    // ─── apyUSD helpers ───

    /// @dev The APYX config with its deploy-time seams resolved for THIS scaffold: the quote leg re-pointed at the
    ///      upstream market just deployed (the config bakes live test-env addresses that don't exist at the fork
    ///      block), and the ERC4626 share-price oracle deployed directly, exactly as the script's oracle phase does
    function _apyUsdConfig() internal returns (DayMarketConfig memory cfg) {
        cfg = registry.getDayMarketConfig("APYX");
        cfg.pool.quoteAsset = upstreamSt;
        cfg.pool.quoteAssetRateProvider = upstreamKernel;
        cfg.oracle.deployed = address(
            _newErc4626Oracle(cfg.collateralAsset, cfg.oracle.specificParams)
        );
        cfg.roycoBlacklist = roycoBlacklist;
        _fundPoolSeed(cfg);
    }

    /// @dev The genesis seed is pulled from the deployment caller: the quote leg is upstream ST SHARES, minted for
    ///      real in setUp, so only the approval is granted here
    function _fundPoolSeed(DayMarketConfig memory _cfg) internal {
        assertGe(IERC20(upstreamSt).balanceOf(DEPLOYER), _cfg.poolInitialization.quoteAmount, "deployer must hold the upstream ST seed");
        vm.prank(DEPLOYER);
        IERC20(upstreamSt).approve(address(template), _cfg.poolInitialization.quoteAmount);
    }

    function _deploy() internal returns (IRoycoProtocolTemplate.DeploymentResult memory) {
        bytes memory p = abi.encode(marketBuilder.buildMarketParams(_apyUsdConfig(), APYUSD_MARKET_ID_SEED, address(factory), DEPLOYER));
        vm.prank(DEPLOYER);
        return factory.executeMarketDeployment(address(template), p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT WIRING (the apyUSD deltas)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The apyUSD pool quotes in the upstream srRoyUSDC senior tranche, registered WITH_RATE against the
    ///         upstream KERNEL — a market's kernel is the canonical rate provider for its senior share — while
    ///         apyUSD's own senior leg is rated by its own kernel, and neither leg pays Balancer yield fees
    function test_ExecuteMarketDeployment_QuoteLegIsTheUpstreamSeniorTranche() external {
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();
        address pool = IRoycoDayKernel(r.kernel).lptAsset();

        IVault vault = IVault(address(GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY).getVault()));
        (IERC20[] memory tokens, TokenInfo[] memory info,,) = vault.getPoolTokenInfo(pool);
        assertEq(tokens.length, 2, "pool token count");
        assertEq(address(tokens[0]), r.seniorTranche, "senior leg must be token0");
        assertEq(address(tokens[1]), upstreamSt, "quote leg must be the upstream senior tranche");

        assertTrue(info[0].tokenType == TokenType.WITH_RATE, "senior leg not WITH_RATE");
        assertEq(address(info[0].rateProvider), r.kernel, "senior rate provider != own kernel");
        assertTrue(info[1].tokenType == TokenType.WITH_RATE, "quote leg not WITH_RATE");
        assertEq(address(info[1].rateProvider), upstreamKernel, "quote rate provider != upstream kernel");
        assertFalse(info[0].paysYieldFees, "senior leg must not pay Balancer yield fees");
        assertFalse(info[1].paysYieldFees, "quote leg must not pay Balancer yield fees");

        // The upstream kernel's live rate marks the NAV-backed senior share the pool prices its quote leg with
        uint256 rate = IRateProvider(upstreamKernel).getRate();
        assertGe(rate, 1e18, "upstream ST rate below the WAD floor");
        assertLt(rate, 1.5e18, "upstream ST rate implausibly high");
    }

    /// @notice The kernel wires the apyUSD collateral stack, and the share-price oracle composes correctly through
    ///         the 18-DECIMAL exchange-rate feed: share price (1.38 apxUSD) x apxUSD/USD — a feed-decimals slip
    ///         (every other market's Chainlink leg is 8 decimals) would blow the composed NAV by 10 orders of magnitude
    function test_ExecuteMarketDeployment_KernelAssetsAndOracle() external {
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();

        IRoycoDayKernel kernel = IRoycoDayKernel(r.kernel);
        assertEq(kernel.collateralAsset(), APYUSD_VAULT, "kernel collateral != apyUSD vault");
        assertEq(kernel.quoteAsset(), upstreamSt, "kernel quote != upstream senior tranche");

        ERC4626SharePriceOracle oracle = ERC4626SharePriceOracle(kernel.getCollateralAssetOracle());
        assertEq(oracle.COLLATERAL_ASSET(), APYUSD_VAULT, "oracle collateral != market collateral");

        // At this pinned block the vault marks ~1.385 apxUSD per share and the feed marks apxUSD at ~$0.79: the two
        // hops must OFFSET into a ~$1.09 composed NAV. A decimals slip on either 18-decimal hop breaks the band
        (NAV_UNIT price,) = oracle.getPrice();
        assertGt(NAV_UNIT.unwrap(price), 0.9e18, "composed share NAV implausibly low");
        assertLt(NAV_UNIT.unwrap(price), 1.5e18, "composed share NAV implausibly high");

        (, int256 answer,,,) = AggregatorV3Interface(APXUSD_USD_FEED).latestRoundData();
        assertEq(
            NAV_UNIT.unwrap(price), IERC4626(APYUSD_VAULT).convertToAssets(1e18).mulDiv(uint256(answer), 1e18), "composed price != share price x exchange rate"
        );
    }

    /// @notice The APYX economics no other config carries land on-chain: the 30-day fixed term in the accountant and
    ///         a ZERO senior self-liquidation bonus in the kernel, alongside the liquidity premium configuration
    function test_ExecuteMarketDeployment_ApyxEconomicsConfigured() external {
        DayMarketConfig memory cfg = registry.getDayMarketConfig("APYX");
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();

        IRoycoDayAccountant.RoycoDayAccountantState memory a = IRoycoDayAccountant(r.accountant).getState();
        assertEq(a.fixedTermDurationSeconds, 30 days, "fixed term != the sheet's 30-day observation period");
        assertEq(a.minLiquidityWAD, cfg.accountant.minLiquidityWAD, "minLiquidityWAD");
        assertEq(a.maxJTYieldShareWAD, cfg.accountant.maxJTYieldShareWAD, "maxJTYieldShareWAD");
        assertEq(a.maxLPTYieldShareWAD, cfg.accountant.maxLPTYieldShareWAD, "maxLPTYieldShareWAD");
        assertLe(uint256(a.maxJTYieldShareWAD) + a.maxLPTYieldShareWAD, 1e18, "caps must sum within the senior gain");
        assertTrue(a.jtYDM != a.lptYDM, "JT and LPT must hold distinct model instances");

        assertEq(IRoycoDayKernel(r.kernel).getState().stSelfLiquidationBonusWAD, 0, "the sheet grants APYX no self-liquidation bonus");
    }

    /// @notice The genesis seed lands in TRANCHE SHARES: the pool opens with quote-only depth paid in upstream ST,
    ///         the dead-share lock is parked, and the deployer's upstream ST balance funds exactly the seed
    function test_ExecuteMarketDeployment_GenesisSeedPaidInUpstreamSeniorShares() external {
        DayMarketConfig memory cfg = registry.getDayMarketConfig("APYX");
        uint256 stBalanceBefore = IERC20(upstreamSt).balanceOf(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();
        address pool = IRoycoDayKernel(r.kernel).lptAsset();

        IVault vault = IVault(address(GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY).getVault()));
        (,, uint256[] memory balances,) = vault.getPoolTokenInfo(pool);
        assertEq(balances[0], 0, "quote-only seed must leave the senior leg empty");
        assertEq(balances[1], cfg.poolInitialization.quoteAmount, "quote leg must hold the full ST-share seed");
        assertEq(IERC20(upstreamSt).balanceOf(DEPLOYER), stBalanceBefore - cfg.poolInitialization.quoteAmount, "seed must be paid by the deployer");

        uint256 deadShares = template.DEAD_SHARES();
        assertEq(IERC20(r.liquidityProviderTranche).balanceOf(template.DEAD_ADDRESS()), deadShares, "dead-share lock must be parked");
        assertGt(IERC20(r.liquidityProviderTranche).balanceOf(DEPLOYER), 0, "deployer must hold the remaining genesis shares");
        assertEq(
            IERC20(r.liquidityProviderTranche).totalSupply(),
            IERC20(r.liquidityProviderTranche).balanceOf(template.DEAD_ADDRESS()) + IERC20(r.liquidityProviderTranche).balanceOf(DEPLOYER),
            "genesis supply must be exactly lock + deployer remainder"
        );
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
