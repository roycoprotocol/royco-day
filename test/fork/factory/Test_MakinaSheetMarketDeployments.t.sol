// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { TokenInfo, TokenType } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { Test } from "../../../lib/forge-std/src/Test.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { ERC4626SharePriceOracleParams, MakinaSharePriceOracleParams } from "../../../script/config/DeploymentTypes.sol";
import { DayMarketRegistry } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketRegistry.sol";
import { DayMarketConfig } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketTypes.sol";
import { DeployMarketComponent } from "../../../script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol";
import { ADMIN_ENTRY_POINT_ROLE, ADMIN_FACTORY_ROLE, JT_LP_ROLE, ST_LP_ROLE, SYNC_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { BaseDeploymentTemplate } from "../../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../../src/libraries/Units.sol";
import { ERC4626SharePriceOracle } from "../../../src/oracle/ERC4626SharePriceOracle.sol";
import { MakinaSharePriceOracle } from "../../../src/oracle/MakinaSharePriceOracle.sol";
import { FactoryScaffold } from "../../utils/FactoryScaffold.sol";
import { TemplateScaffold } from "../../utils/TemplateScaffold.sol";

/// @title MakinaSheetMarketDeploymentBase
/// @notice Shared fork fixture for the two Makina sheet markets (DMG and DUSD): each deploys the upstream srRoyUSDC
///         market from its own config first (the sheet markets' pools quote in the srRoyUSDC senior tranche, and the
///         config bakes live addresses that do not exist at the fork block), then the Makina market from ITS registry
///         config through the script's own oracle phase (`deployCollateralOracle`) and the factory's single wiring
///         transaction.
/// @dev Requires a mainnet fork (real Balancer V3 + Gyro E-CLP + the REAL Makina machines). FAILS (env not found)
///      when `MAINNET_RPC_URL` is unset, instead of silently passing.
abstract contract MakinaSheetMarketDeploymentBase is Test {
    uint256 internal constant FORK_BLOCK = 25_400_000;
    address internal constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;
    address internal constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    /// @dev The upstream market's collateral, funding the deployer's senior-share mint
    address internal constant SRROYUSDC_VAULT = 0xcD9f5907F92818bC06c9Ad70217f089E190d2a32;

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

    address internal upstreamSt;
    address internal upstreamJt;
    address internal upstreamKernel;

    bytes32 internal constant SRROYUSDC_MARKET_ID_SEED = keccak256("SRROYUSDC_UPSTREAM_SEED");

    // ─── per-market hooks ───

    /// @dev The registry name of the Makina market under test
    function _marketName() internal pure virtual returns (string memory);
    /// @dev The market's REAL Makina machine (cross-checked against the config in setUp)
    function _machine() internal pure virtual returns (address);
    /// @dev The machine's share token, the market's collateral asset
    function _collateral() internal pure virtual returns (address);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);

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
        DayMarketConfig memory cfg = registry.getDayMarketConfig(_marketName());
        assertEq(cfg.collateralAsset, _collateral(), "config collateral != machine share token");
        MakinaSharePriceOracleParams memory p = abi.decode(cfg.oracle.specificParams, (MakinaSharePriceOracleParams));
        assertEq(p.makinaMachine, _machine(), "config machine != the market's Makina machine");
        assertEq(p.accountingAssetToNavAssetFeed, USDC_USD_FEED, "config feed != Chainlink USDC/USD");

        _deployUpstreamSrRoyUsdc();
        _mintUpstreamSeniorShares();
    }

    // ─── upstream (srRoyUSDC) helpers, mirroring Test_ApyUsdMarketDeployment ───

    function _deployUpstreamSrRoyUsdc() internal {
        DayMarketConfig memory cfg = registry.getDayMarketConfig("srRoyUSDC");
        ERC4626SharePriceOracleParams memory op = abi.decode(cfg.oracle.specificParams, (ERC4626SharePriceOracleParams));
        cfg.oracle.deployed = address(
            new ERC4626SharePriceOracle(
                cfg.collateralAsset,
                op.queryMode,
                op.baseAssetToNavAssetFeed,
                op.minDeviationWAD,
                op.lastUpdate,
                op.chainlinkOracleStalenessThresholdSeconds,
                op.vaultSharePriceStalenessThresholdSeconds
            )
        );
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

    /// @dev Junior first (coverage opens senior capacity), then the senior deposit that funds the genesis seed
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

    // ─── the Makina market under test ───

    /// @dev The registry config with its deploy-time seams resolved for THIS scaffold: the quote leg re-pointed at
    ///      the upstream market just deployed, and the collateral oracle deployed through the SCRIPT'S OWN oracle
    ///      phase — the exact `deployCollateralOracle` recipe production runs
    function _marketConfig() internal returns (DayMarketConfig memory cfg) {
        cfg = registry.getDayMarketConfig(_marketName());
        cfg.pool.quoteAsset = upstreamSt;
        cfg.pool.quoteAssetRateProvider = upstreamKernel;
        cfg.oracle.deployed = marketBuilder.deployCollateralOracle(cfg, _marketIdSeed());
        vm.prank(DEPLOYER);
        IERC20(upstreamSt).approve(address(template), cfg.poolInitialization.quoteAmount);
    }

    function _marketIdSeed() internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_marketName(), "_TEST_SEED"));
    }

    function _deploy() internal returns (IRoycoProtocolTemplate.DeploymentResult memory) {
        bytes memory p = abi.encode(marketBuilder.buildMarketParams(_marketConfig(), _marketIdSeed(), address(factory), DEPLOYER));
        vm.prank(DEPLOYER);
        return factory.executeMarketDeployment(address(template), p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SHARED ASSERTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The pool quotes in the upstream srRoyUSDC senior tranche (WITH_RATE, upstream kernel as provider);
    ///         the market's own senior leg is rated by its own kernel; neither leg pays Balancer yield fees
    function test_ExecuteMarketDeployment_QuoteLegIsTheUpstreamSeniorTranche() external {
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();
        address pool = IRoycoDayKernel(r.kernel).lptAsset();

        IVault vault = IVault(address(GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY).getVault()));
        (IERC20[] memory tokens, TokenInfo[] memory info,,) = vault.getPoolTokenInfo(pool);
        assertEq(address(tokens[0]), r.seniorTranche, "senior leg must be token0");
        assertEq(address(tokens[1]), upstreamSt, "quote leg must be the upstream senior tranche");
        assertTrue(info[0].tokenType == TokenType.WITH_RATE && address(info[0].rateProvider) == r.kernel, "senior leg not kernel-rated");
        assertTrue(info[1].tokenType == TokenType.WITH_RATE && address(info[1].rateProvider) == upstreamKernel, "quote leg not upstream-kernel-rated");
        assertFalse(info[0].paysYieldFees || info[1].paysYieldFees, "no leg may pay Balancer yield fees");
    }

    /// @notice The kernel wires the machine-share collateral, and the Makina share-price oracle (deployed through
    ///         the script's oracle phase) composes machine accounting x USDC/USD into a plausible ~$1 share NAV
    function test_ExecuteMarketDeployment_KernelAssetsAndMakinaOracle() external {
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();

        IRoycoDayKernel kernel = IRoycoDayKernel(r.kernel);
        assertEq(kernel.collateralAsset(), _collateral(), "kernel collateral != machine share token");
        assertEq(kernel.quoteAsset(), upstreamSt, "kernel quote != upstream senior tranche");

        MakinaSharePriceOracle oracle = MakinaSharePriceOracle(kernel.getCollateralAssetOracle());
        assertEq(oracle.COLLATERAL_ASSET(), _collateral(), "oracle collateral != market collateral");

        // Both machines mark ~1.00-1.04 USDC per share at this block; a decimals slip on the 6-decimal accounting
        // hop would blow this band by orders of magnitude
        (NAV_UNIT price,) = oracle.getPrice();
        assertGt(NAV_UNIT.unwrap(price), 0.95e18, "composed machine-share NAV implausibly low");
        assertLt(NAV_UNIT.unwrap(price), 1.2e18, "composed machine-share NAV implausibly high");
    }

    /// @notice The genesis seed lands in upstream ST shares: quote-only depth, dead-share lock parked, remainder held
    function test_ExecuteMarketDeployment_GenesisSeedPaidInUpstreamSeniorShares() external {
        DayMarketConfig memory cfg = registry.getDayMarketConfig(_marketName());
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();
        address pool = IRoycoDayKernel(r.kernel).lptAsset();

        IVault vault = IVault(address(GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY).getVault()));
        (,, uint256[] memory balances,) = vault.getPoolTokenInfo(pool);
        assertEq(balances[0], 0, "quote-only seed must leave the senior leg empty");
        assertEq(balances[1], cfg.poolInitialization.quoteAmount, "quote leg must hold the full ST-share seed");
        assertEq(IERC20(r.liquidityProviderTranche).balanceOf(template.DEAD_ADDRESS()), template.DEAD_SHARES(), "dead-share lock must be parked");
    }
}

/// @title Test_DmgMarketDeployment
/// @notice DMG: the mGLOBAL machine market — no fixed term, 1% self-liquidation bonus, liquidation utilization 2e18
contract Test_DmgMarketDeployment is MakinaSheetMarketDeploymentBase {
    function _marketName() internal pure override returns (string memory) {
        return "DMG";
    }

    function _machine() internal pure override returns (address) {
        return 0xC4fFab8540AC27E40D4e2930517aA711e9C00c5b;
    }

    function _collateral() internal pure override returns (address) {
        return 0x761C3B16a5Afdd7A1869C4B979cFF3383d5Fe98B;
    }

    /// @notice The DMG economics land on-chain: NO fixed term and the 1% senior self-liquidation bonus
    function test_ExecuteMarketDeployment_DmgEconomicsConfigured() external {
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = IRoycoDayAccountant(r.accountant).getState();
        assertEq(a.fixedTermDurationSeconds, 0, "DMG runs with no fixed term");
        assertEq(a.maxLPTYieldShareWAD, 0, "LPT liquidity premium must be disabled");
        assertEq(IRoycoDayKernel(r.kernel).getState().stSelfLiquidationBonusWAD, 0.01e18, "DMG self-liquidation bonus");
    }
}

/// @title Test_DusdMarketDeployment
/// @notice DUSD: the dUSD machine market — 2-day fixed term, 3% self-liquidation bonus (dawn values, TODO-flagged there)
contract Test_DusdMarketDeployment is MakinaSheetMarketDeploymentBase {
    function _marketName() internal pure override returns (string memory) {
        return "DUSD";
    }

    function _machine() internal pure override returns (address) {
        return 0x6b006870C83b1Cd49E766Ac9209f8d68763Df721;
    }

    function _collateral() internal pure override returns (address) {
        return 0x1e33E98aF620F1D563fcD3cfd3C75acE841204ef;
    }

    /// @notice The DUSD economics land on-chain: the 2-day fixed term and the 3% senior self-liquidation bonus
    function test_ExecuteMarketDeployment_DusdEconomicsConfigured() external {
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = IRoycoDayAccountant(r.accountant).getState();
        assertEq(a.fixedTermDurationSeconds, 2 days, "DUSD fixed term");
        assertEq(a.maxLPTYieldShareWAD, 0, "LPT liquidity premium must be disabled");
        assertEq(IRoycoDayKernel(r.kernel).getState().stSelfLiquidationBonusWAD, 0.03e18, "DUSD self-liquidation bonus");
    }
}
