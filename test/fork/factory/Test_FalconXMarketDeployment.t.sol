// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRateProvider } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { TokenInfo, TokenType } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { Test } from "../../../lib/forge-std/src/Test.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { ERC4626SharePriceOracleParams, IdleCDOTranchePriceOracleParams } from "../../../script/config/DeploymentTypes.sol";
import { DayMarketRegistry } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketRegistry.sol";
import { DayMarketConfig } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketTypes.sol";
import { DeployMarketComponent } from "../../../script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol";
import { ADMIN_ENTRY_POINT_ROLE, ADMIN_FACTORY_ROLE, JT_LP_ROLE, ST_LP_ROLE, SYNC_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { RoycoFactoryGatekeeper } from "../../../src/factory/RoycoFactoryGatekeeper.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { AggregatorV3Interface } from "../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IIdleCDO } from "../../../src/interfaces/external/idle-finance/IIdleCDO.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../../src/libraries/Units.sol";
import { TrancheType } from "../../../src/libraries/Types.sol";
import { ERC4626SharePriceOracle } from "../../../src/oracle/ERC4626SharePriceOracle.sol";
import { IdleCDOTranchePriceOracle } from "../../../src/oracle/IdleCDOTranchePriceOracle.sol";
import { ClockedChainlinkPriceOracleBase } from "../../../src/oracle/base/ClockedChainlinkPriceOracleBase.sol";
import { ChainlinkPriceOracleBase } from "../../../src/oracle/base/ChainlinkPriceOracleBase.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { FactoryScaffold } from "../../utils/FactoryScaffold.sol";
import { TemplateScaffold } from "../../utils/TemplateScaffold.sol";

/// @title Test_FalconXMarketDeployment
/// @notice Fork test for the FalconX market config: a Pareto IdleCDO AA-tranche collateral behind the composed
///         virtual-price x USDC/USD oracle, whose LPT pool quotes in ANOTHER ROYCO MARKET'S SENIOR TRANCHE
///         (srRoyUSDC's), with that market's kernel as the quote leg's rate provider. Covers the deltas no other
///         suite reaches: the first cross-market pool (ST-share quote leg rated by a foreign kernel), a genesis seed
///         paid in tranche shares the deployer must first mint upstream, and the deploy-time `lastUpdate`
///         attestation the config deliberately ships unset.
/// @dev The config bakes the live test-environment srRoyUSDC addresses, which do not exist at this fork block, so
///      setUp deploys the srRoyUSDC market from its own config first and points FalconX's quote leg at it — the same
///      composition the production deployment performs, executed end-to-end. Requires a mainnet fork. FAILS (env not
///      found) when `MAINNET_RPC_URL` is unset, instead of silently passing.
contract Test_FalconXMarketDeployment is Test {
    using Math for uint256;

    uint256 internal constant FORK_BLOCK = 25_400_000;
    address internal constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;

    /// @dev The market's real mainnet contract set, cross-checked on-chain in setUp so a config drift fails loudly
    address internal constant PARETO_FALCONX_CDO = 0x433D5B175148dA32Ffe1e1A37a939E1b7e79be4d;
    address internal constant AA_TRANCHE_TOKEN = 0xC26A6Fa2C37b38E549a4a1807543801Db684f99C; // 18 decimals, USDC underlying
    address internal constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // Chainlink, 8 decimals

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
    bytes32 internal constant FALCONX_MARKET_ID_SEED = keccak256("FALCONX_TEST_SEED");

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc, FORK_BLOCK);

        am = new RoycoAccessManager(address(this));
        (factory, gatekeeper, entryPoint, syncer) = FactoryScaffold.deployFactory(am, keccak256("FACTORY_PROXY"));
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

        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));

        // Pin the FalconX config's external addresses against the live chain, so an address typo in the config file
        // fails here with a named reason instead of deep inside a deployment
        DayMarketConfig memory cfg = registry.getDayMarketConfig("FalconX");
        assertEq(cfg.collateralAsset, AA_TRANCHE_TOKEN, "config collateral != Pareto AA tranche");
        assertEq(IIdleCDO(PARETO_FALCONX_CDO).AATranche(), AA_TRANCHE_TOKEN, "AA tranche is not the configured CDO's");
        assertEq(IERC20Metadata(AA_TRANCHE_TOKEN).decimals(), 18, "AA tranche decimals drifted");
        IdleCDOTranchePriceOracleParams memory p = abi.decode(cfg.oracle.specificParams, (IdleCDOTranchePriceOracleParams));
        assertEq(p.idleCDO, PARETO_FALCONX_CDO, "config CDO != Pareto FalconX CDO");
        assertEq(p.underlyingTokenToNavAssetFeed, USDC_USD_FEED, "config feed != Chainlink USDC/USD");

        // Stand up the quote-side dependency: the srRoyUSDC market, then real senior shares for the deployer
        _deployUpstreamSrRoyUsdc();
        _mintUpstreamSeniorShares();
    }

    // ─── upstream (srRoyUSDC) helpers ───

    /// @dev Deploys the srRoyUSDC market from its own config, exactly as Test_SrRoyUsdcMarketDeployment does: the
    ///      ERC4626 share-price oracle is deployed directly and the 18-decimal sUSDe genesis seed is dealt
    function _deployUpstreamSrRoyUsdc() internal {
        DayMarketConfig memory cfg = registry.getDayMarketConfig("srRoyUSDC");
        cfg.oracle.deployed = address(_newErc4626Oracle(cfg.collateralAsset, cfg.oracle.specificParams));
        _resolveYdms(cfg);
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
    ///      20% coverage requirement opens senior capacity, then the senior deposit that funds the FalconX genesis
    ///      seed. Dealing ST shares instead would fabricate supply with no NAV behind it and distort the kernel rate.
    function _mintUpstreamSeniorShares() internal {
        am.grantRole(JT_LP_ROLE, DEPLOYER, 0);
        am.grantRole(ST_LP_ROLE, DEPLOYER, 0);

        // The upstream market enforces BOTH sides on the senior deposit: 20% junior coverage below it and a 50%
        // market-making floor above it, against a genesis pool holding only ~1 sUSDe (~$1.24) of quote depth. The
        // junior leg is generous; the senior mint stays small enough that half its NAV fits the genesis liquidity,
        // while still covering the 1e6-share FalconX seed
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

    // ─── FalconX helpers ───

    /// @dev The FalconX config with its two deploy-time seams resolved for THIS scaffold: the quote leg re-pointed at
    ///      the upstream market just deployed (the config bakes live test-env addresses that don't exist at the fork
    ///      block), and the CDO deviation clock attested to now — the step the config's `lastUpdate: 0` demands
    function _falconConfig() internal returns (DayMarketConfig memory cfg) {
        cfg = registry.getDayMarketConfig("FalconX");
        cfg.pool.quoteAsset = upstreamSt;
        cfg.pool.quoteAssetRateProvider = upstreamKernel;
        cfg.oracle.deployed = _deployCollateralOracle(cfg, uint32(block.timestamp));
        _resolveYdms(cfg);
        _fundPoolSeed(cfg);
    }

    /// @dev Resolves (or deploys) the market's yield distribution model instances, mirroring the pipeline
    function _resolveYdms(DayMarketConfig memory _cfg) internal {
        if (_cfg.accountant.jtYdm.deployed == address(0)) _cfg.accountant.jtYdm.deployed = marketBuilder.deployYDM("JT model  ", _cfg.accountant.jtYdm);
        if (_cfg.accountant.lptYdm.deployed == address(0)) _cfg.accountant.lptYdm.deployed = marketBuilder.deployYDM("LPT model ", _cfg.accountant.lptYdm);
    }

    function _deployCollateralOracle(DayMarketConfig memory _cfg, uint32 _attestedLastUpdate) internal returns (address) {
        IdleCDOTranchePriceOracleParams memory p = abi.decode(_cfg.oracle.specificParams, (IdleCDOTranchePriceOracleParams));
        return address(
            new IdleCDOTranchePriceOracle(
                p.idleCDO,
                _cfg.collateralAsset,
                p.underlyingTokenToNavAssetFeed,
                p.minDeviationWAD,
                _attestedLastUpdate,
                p.chainlinkOracleStalenessThresholdSeconds,
                p.cdoPriceStalenessThresholdSeconds
            )
        );
    }

    /// @dev The genesis seed is pulled from the deployment caller: the quote leg is upstream ST SHARES, minted for
    ///      real in setUp, so only the approval is granted here
    function _fundPoolSeed(DayMarketConfig memory _cfg) internal {
        assertGe(IERC20(upstreamSt).balanceOf(DEPLOYER), _cfg.poolInitialization.quoteAmount, "deployer must hold the upstream ST seed");
        vm.prank(DEPLOYER);
        IERC20(upstreamSt).approve(address(template), _cfg.poolInitialization.quoteAmount);
    }

    function _deploy() internal returns (IRoycoProtocolTemplate.DeploymentResult memory) {
        bytes memory p = abi.encode(marketBuilder.buildMarketParams(_falconConfig(), FALCONX_MARKET_ID_SEED, address(factory), DEPLOYER));
        vm.prank(DEPLOYER);
        return factory.executeMarketDeployment(address(template), p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT WIRING (the FalconX deltas)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The FalconX pool is the first CROSS-MARKET pool: its quote leg is the upstream srRoyUSDC senior
    ///         tranche, registered WITH_RATE against the upstream KERNEL — a market's kernel is the canonical rate
    ///         provider for its senior share — while FalconX's own senior leg is rated by its own kernel
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

        // The upstream kernel's live rate marks the NAV-backed senior share the pool prices its quote leg with: at
        // least the 1 WAD floor, and within a sane band of one NAV unit for a freshly seeded market
        uint256 rate = IRateProvider(upstreamKernel).getRate();
        assertGe(rate, 1e18, "upstream ST rate below the WAD floor");
        assertLt(rate, 1.5e18, "upstream ST rate implausibly high");
    }

    /// @notice The kernel wires the CDO collateral stack: the AA tranche as collateral, and the composed oracle
    ///         pricing it as (virtual price lifted to WAD) x (USDC/USD feed) against the LIVE Pareto CDO
    function test_ExecuteMarketDeployment_ComposedVirtualPriceOracle() external {
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();

        IRoycoDayKernel kernel = IRoycoDayKernel(r.kernel);
        assertEq(kernel.collateralAsset(), AA_TRANCHE_TOKEN, "kernel collateral != AA tranche");
        assertEq(kernel.quoteAsset(), upstreamSt, "kernel quote != upstream senior tranche");

        IdleCDOTranchePriceOracle oracle = IdleCDOTranchePriceOracle(kernel.getCollateralAssetOracle());
        assertEq(oracle.IDLE_CDO(), PARETO_FALCONX_CDO, "oracle CDO != configured CDO");
        assertEq(oracle.COLLATERAL_ASSET(), AA_TRANCHE_TOKEN, "oracle collateral != market collateral");
        IdleCDOTranchePriceOracleParams memory p = abi.decode(registry.getDayMarketConfig("FalconX").oracle.specificParams, (IdleCDOTranchePriceOracleParams));
        assertEq(oracle.MIN_DEVIATION_WAD(), p.minDeviationWAD, "deviation threshold != configured");

        // The composed price is live against the real CDO: AA virtual price lifted from the underlying's decimals to
        // WAD, times the real feed answer lifted from feed decimals, floored in one mulDiv
        uint256 virtualPriceWAD =
            IIdleCDO(PARETO_FALCONX_CDO).virtualPrice(AA_TRANCHE_TOKEN) * 10 ** (18 - IERC20Metadata(IIdleCDO(PARETO_FALCONX_CDO).token()).decimals());
        (, int256 answer,,,) = AggregatorV3Interface(USDC_USD_FEED).latestRoundData();
        (NAV_UNIT price,) = oracle.getPrice();
        assertEq(
            NAV_UNIT.unwrap(price),
            virtualPriceWAD.mulDiv(uint256(answer), 10 ** AggregatorV3Interface(USDC_USD_FEED).decimals()),
            "composed price != CDO virtual price x feed"
        );
    }

    /// @notice THE payoff of per-hop staleness: three days into the market's life the 48h Chainlink hop is stale and
    ///         pricing fails shut with the FEED's error, even though the 8-day virtual-price clock is still fresh —
    ///         under the old single kernel threshold (sized to 8 days for Pareto's weekly cadence) this exact window
    ///         priced happily against a 3-day-old feed. Freshen the feed past the clock's gate and the VIRTUAL
    ///         PRICE's error takes over: each hop is judged on its own immutable clock and names itself
    function test_PerHopStaleness_FeedGateStaysTightDespiteTheSlowClock() external {
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();
        IdleCDOTranchePriceOracle oracle = IdleCDOTranchePriceOracle(IRoycoDayKernel(r.kernel).getCollateralAssetOracle());
        IdleCDOTranchePriceOracleParams memory p = abi.decode(registry.getDayMarketConfig("FalconX").oracle.specificParams, (IdleCDOTranchePriceOracleParams));
        assertEq(oracle.FEED_STALENESS_THRESHOLD_SECONDS(), p.chainlinkOracleStalenessThresholdSeconds, "feed threshold != configured immutable");
        assertEq(oracle.SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS(), p.cdoPriceStalenessThresholdSeconds, "clock threshold != configured immutable");
        assertLt(oracle.FEED_STALENESS_THRESHOLD_SECONDS(), oracle.SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS(), "the delta only exists when the gates differ");

        // Three days: past the feed's 48h gate, inside the clock's 8-day gate — the FEED hop fails shut
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(ChainlinkPriceOracleBase.STALE_FEED_PRICE.selector);
        oracle.getPrice();

        // Nine days total, with the feed mocked fresh: the CLOCK hop is now the stale one and names itself
        vm.warp(block.timestamp + 6 days);
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) = AggregatorV3Interface(USDC_USD_FEED).latestRoundData();
        vm.mockCall(
            USDC_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, answer, block.timestamp, block.timestamp, answeredInRound)
        );
        vm.expectRevert(ClockedChainlinkPriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.getPrice();
    }

    /// @notice Deploying without a live attestation of the CDO clock — a zero `lastUpdate`, or one older than the
    ///         staleness threshold — dies atomically: the shut deviation clock gates pricing, and the genesis pool
    ///         seeding rates the senior leg through the market's own kernel, which pokes the shut oracle. The config
    ///         bakes a REAL attested timestamp, which is exactly why it must be re-attested before every deploy
    function test_RevertIf_TheVirtualPriceClockIsNotAttested() external {
        DayMarketConfig memory cfg = registry.getDayMarketConfig("FalconX");

        cfg.pool.quoteAsset = upstreamSt;
        cfg.pool.quoteAssetRateProvider = upstreamKernel;
        cfg.oracle.deployed = _deployCollateralOracle(cfg, 0); // unattested: pricing held shut
        _resolveYdms(cfg);
        _fundPoolSeed(cfg);

        bytes memory params = abi.encode(marketBuilder.buildMarketParams(cfg, FALCONX_MARKET_ID_SEED, address(factory), DEPLOYER));
        vm.prank(DEPLOYER);
        vm.expectRevert();
        factory.executeMarketDeployment(address(template), params);
    }

    /// @notice The genesis seed lands in TRANCHE SHARES: the pool opens with quote-only depth paid in upstream ST,
    ///         the dead-share lock is parked, and the deployer's upstream ST balance funds exactly the seed
    function test_ExecuteMarketDeployment_GenesisSeedPaidInUpstreamSeniorShares() external {
        DayMarketConfig memory cfg = registry.getDayMarketConfig("FalconX");
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

    /// @notice The sheet economics land in the accountant: the 10% market-making floor, the never-binding premium
    ///         caps, and ONE shared AdaptiveCurve_V2 instance recorded in both slots with the JT risk premium and
    ///         LPT liquidity premium curves initialized on it per tranche type
    function test_ExecuteMarketDeployment_FalconXEconomicsConfigured() external {
        DayMarketConfig memory cfg = registry.getDayMarketConfig("FalconX");
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy();

        IRoycoDayAccountant.RoycoDayAccountantState memory a = IRoycoDayAccountant(r.accountant).getState();
        assertEq(a.minLiquidityWAD, cfg.accountant.minLiquidityWAD, "minLiquidityWAD");
        assertEq(a.maxJTYieldShareWAD, cfg.accountant.maxJTYieldShareWAD, "maxJTYieldShareWAD");
        assertEq(a.maxLPTYieldShareWAD, cfg.accountant.maxLPTYieldShareWAD, "maxLPTYieldShareWAD");
        assertLe(uint256(a.maxJTYieldShareWAD) + a.maxLPTYieldShareWAD, 1e18, "caps must sum within the senior gain");
        assertEq(a.jtYDM, a.lptYDM, "both slots must share the chain-wide V2 instance");
        assertEq(a.jtYDM, r.ydm, "accountant JT model != resolved instance");
        assertEq(a.lptYDM, r.lptYdm, "accountant LPT model != resolved instance");

        // The shared instance carries a curve per tranche type: the config's JT (0.005, 0.045, 0.31) and LPT
        // (0.051, 0.091, 0.31) curves decompose to (target, discount-at-zero, premium-at-full)
        (uint64 jtTarget,, uint64 jtDiscount, uint64 jtPremium) = AdaptiveCurveYDM_V2(r.ydm).accountantToCurve(r.accountant, TrancheType.JUNIOR);
        assertEq(jtTarget, 0.045e18, "JT curve target");
        assertEq(jtDiscount, 0.04e18, "JT curve discount at zero util");
        assertEq(jtPremium, 0.265e18, "JT curve premium at full util");
        (uint64 lptTarget,, uint64 lptDiscount, uint64 lptPremium) = AdaptiveCurveYDM_V2(r.ydm).accountantToCurve(r.accountant, TrancheType.LIQUIDITY_PROVIDER);
        assertEq(lptTarget, 0.091e18, "LPT curve target");
        assertEq(lptDiscount, 0.04e18, "LPT curve discount at zero util");
        assertEq(lptPremium, 0.219e18, "LPT curve premium at full util");
    }

    /// @dev Deploys the config's ERC4626 share-price adapter with its per-hop staleness immutable, as the script does
    function _newErc4626Oracle(address _collateral, bytes memory _oracleParams) internal returns (ERC4626SharePriceOracle) {
        ERC4626SharePriceOracleParams memory op = abi.decode(_oracleParams, (ERC4626SharePriceOracleParams));
        return new ERC4626SharePriceOracle(
            _collateral,
            op.baseAssetToNavAssetFeed,
            op.minDeviationWAD,
            op.lastUpdate,
            op.chainlinkOracleStalenessThresholdSeconds,
            op.vaultSharePriceStalenessThresholdSeconds
        );
    }
}
