// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ILPOracleBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleBase.sol";
import { ILPOracleFactoryBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { TokenInfo, TokenType } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { LPOracleBase } from "../../../lib/balancer-v3-monorepo/pkg/oracles/contracts/LPOracleBase.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { Test } from "../../../lib/forge-std/src/Test.sol";
import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { DayMarketRegistry } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketRegistry.sol";
import { DayMarketConfig } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketTypes.sol";
import { DeployMarketComponent } from "../../../script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol";
import { ADMIN_ENTRY_POINT_ROLE, ADMIN_FACTORY_ROLE, ADMIN_ORACLE_ROLE, SYNC_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { RoycoFactoryGatekeeper } from "../../../src/factory/RoycoFactoryGatekeeper.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { BaseDeploymentTemplate } from "../../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { AggregatorV3Interface } from "../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IIdleCDO } from "../../../src/interfaces/external/idle-finance/IIdleCDO.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { BalancerV3LiquidityVenue } from "../../../src/kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import { NAV_UNIT } from "../../../src/libraries/Units.sol";
import { IdleCDOTranchePriceOracle } from "../../../src/oracle/IdleCDOTranchePriceOracle.sol";
import { FactoryScaffold } from "../../utils/FactoryScaffold.sol";
import { TemplateScaffold } from "../../utils/TemplateScaffold.sol";

/// @title Test_IdleCDOMarketDeployment
/// @notice Fork test for the single Day template (`RoycoDayBalancerV3MarketDeploymentTemplate`) deployed against a
///         market whose collateral is a REAL Idle CDO AA tranche priced by the fully immutable
///         `IdleCDOTranchePriceOracle` adapter, modeled on Test_RoycoFactory's direct-template pattern. Covers the
///         deltas the golden ERC4626 suite cannot: the immutable adapter's CDO threading + tranche-identity guard,
///         the live virtual-price composition against the real CDO + feed, the deviation-clock timestamp seam, the
///         BPT oracle injection, the pricing-admin selector role bindings, and the senior pool leg's kernel rate provider.
/// @dev Requires a mainnet fork (real Balancer V3 + Gyro E-CLP + the REAL Pareto Idle CDO). FAILS (env not
///      found) when `MAINNET_RPC_URL` is unset, instead of silently passing.
contract Test_IdleCDOMarketDeployment is Test {
    /// @dev The address that supplies each market's genesis pool liquidity in this suite
    using Math for uint256;

    uint256 internal constant FORK_BLOCK = 25_400_000;
    address internal constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;
    address internal constant ECLP_LP_ORACLE_FACTORY = 0x301EDe5Fd4f9d7266B09c3A2E38F97776447154B;

    /// @dev IdleCDO contract address (Pareto Falconx Prime Brokerage Vault)
    address internal constant PARETO_FALCONX_CDO = 0x433D5B175148dA32Ffe1e1A37a939E1b7e79be4d;

    /// @dev AA Tranche token address (the market's collateral asset)
    address internal constant AA_TRANCHE_TOKEN = 0xC26A6Fa2C37b38E549a4a1807543801Db684f99C;

    /// @notice Chainlink USDC / USD feed, the underlying-token->NAV leg of the composed oracle
    address internal constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    /// @dev The deviation-clock threshold the adapter pins as a construction immutable (0.1%)
    uint256 internal constant MIN_DEVIATION_WAD = 0.001e18;

    /// @dev The per-hop staleness immutables: the Chainlink leg tight (24h heartbeat doubled), the virtual-price
    ///      clock wide (Pareto steps the CDO NAV ~weekly)
    uint32 internal constant FEED_STALENESS_THRESHOLD_SECONDS = 48 hours;
    uint32 internal constant CDO_PRICE_STALENESS_THRESHOLD_SECONDS = 8 days;

    address internal constant SNUSD_VAULT = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313; // non-tranche collateral for the guard test

    RoycoAccessManager internal am;
    RoycoFactoryGatekeeper internal gatekeeper;
    RoycoFactory internal factory;
    DayMarketRegistry internal registry;
    DeployMarketComponent internal marketBuilder;
    RoycoDayBalancerV3MarketDeploymentTemplate internal template;
    IRoycoDayEntryPoint internal entryPoint;
    RoycoMarketSyncer internal syncer;

    /// @dev The chain's blacklist singleton, pinned into the template at construction
    address internal roycoBlacklist;

    address internal FACTORY_ADMIN = makeAddr("FACTORY_ADMIN");
    address internal DEPLOYER = makeAddr("DEPLOYER");
    address internal PROTOCOL_FEE_RECIPIENT = makeAddr("PROTOCOL_FEE_RECIPIENT");

    /// @dev Pre-mined marketId whose senior-tranche CREATE3 proxy sorts below the quote asset (ST is pool token0) for
    ///      this suite's deterministic `factory`; the deployment path asserts that ordering. Mined via script/mine-market-id.
    bytes32 internal constant MARKET_ID = 0x7537556461b25c033e9fe151342e829a6439dc9c0f467afe0667ee9235315cae;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc, FORK_BLOCK);

        // This test contract is the AccessManager admin (ADMIN_ROLE).
        am = new RoycoAccessManager(address(this));

        // The factory proxy takes a CREATE3 address, a function of its salt alone, which is what lets the gatekeeper
        // and the factory each hold the other as a constructor immutable. The scaffold stands both up and binds the
        // factory's own selectors and roles, exactly as the deployment script does.
        (factory, gatekeeper, entryPoint, syncer) = FactoryScaffold.deployFactory(am, keccak256("FACTORY_PROXY"));

        // Every market the template deploys screens against this one blacklist, and the template rejects a null one
        roycoBlacklist = FactoryScaffold.deployBlacklist(am);

        // Grant the factory-facing roles the initialize() call bound to selectors.
        am.grantRole(ADMIN_FACTORY_ROLE, FACTORY_ADMIN, 0);

        // The scaffold deployed the REAL periphery singletons alongside the gatekeeper that pins them

        // Bind the config selectors the factory drives during deployments (the factory self-granted
        // ADMIN_ENTRY_POINT_ROLE + SYNC_ROLE in its initialize).
        bytes4[] memory entryPointSelectors = new bytes4[](1);
        entryPointSelectors[0] = IRoycoDayEntryPoint.modifyTrancheConfigs.selector;
        am.setTargetFunctionRole(address(entryPoint), entryPointSelectors, ADMIN_ENTRY_POINT_ROLE);
        bytes4[] memory syncerSelectors = new bytes4[](1);
        syncerSelectors[0] = RoycoMarketSyncer.addMarketKernels.selector;
        am.setTargetFunctionRole(address(syncer), syncerSelectors, SYNC_ROLE);

        // The real Day template, bound to this factory, stood up through the real per-component deploy scripts.
        // The template deploys every market contract itself, so the script only builds the params (`buildMarketParams`).
        TemplateScaffold.Result memory scaffold = TemplateScaffold.standUp(am, factory, roycoBlacklist);
        registry = scaffold.registry;
        marketBuilder = scaffold.market;
        template = scaffold.template;

        // The template resolves a market's yield distribution models out of its own registry, so bind its registration
        // surface and register the config's shapes, exactly as the scaffolding phase does.
        bytes4[] memory ydmSelectors = new bytes4[](1);
        ydmSelectors[0] = BaseDeploymentTemplate.setYieldDistributionModels.selector;
        am.setTargetFunctionRole(address(template), ydmSelectors, ADMIN_FACTORY_ROLE);
        am.grantRole(ADMIN_FACTORY_ROLE, address(scaffold.ydms), 0);
        scaffold.ydms.registerModels();
    }

    // ─── helpers ───

    function _register() internal {
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));
    }

    /// @dev Deploys the Idle CDO tranche oracle exactly as the production script does: a single direct deployment
    ///      with every parameter (CDO, tranche, feed, threshold, attested checkpoint) a construction immutable, no
    ///      proxy, no beacon, no authority (mirrors `_deployCollateralAssetOracle`).
    function _deployIdleOracle(address _tranche) internal returns (address oracle) {
        // The attested last update is now: the deployer vouches the virtual price is current at deployment.
        return address(
            new IdleCDOTranchePriceOracle(
                PARETO_FALCONX_CDO,
                _tranche,
                USDC_USD_FEED,
                MIN_DEVIATION_WAD,
                uint32(block.timestamp),
                FEED_STALENESS_THRESHOLD_SECONDS,
                CDO_PRICE_STALENESS_THRESHOLD_SECONDS
            )
        );
    }

    /// @dev Every market is deployed with genesis pool liquidity, so the configured funder must hold the quote and
    ///      have approved the template before `executeMarketDeployment`. Points the seed at a test-controlled funder
    function _fundPoolSeed(DayMarketConfig memory _cfg) internal {
        deal(_cfg.pool.quoteAsset, DEPLOYER, _cfg.poolInitialization.quoteAmount);
        vm.prank(DEPLOYER);
        IERC20(_cfg.pool.quoteAsset).approve(address(template), _cfg.poolInitialization.quoteAmount);
    }

    /// @dev Clones the snUSD market config in memory and swaps in the CDO AA tranche collateral + its proxied
    ///      virtual-price oracle. The direct-template path must supply the deployed oracle itself (the `deploy()` flow resolves it).
    function _marketConfig() internal returns (DayMarketConfig memory cfg) {
        cfg = registry.getDayMarketConfig("snUSD");
        cfg.collateralAsset = AA_TRANCHE_TOKEN;
        cfg.oracle.deployed = _deployIdleOracle(AA_TRANCHE_TOKEN);
        _fundPoolSeed(cfg);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT WIRING (the Idle-CDO-specific deltas)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The immutable adapter pins the REAL CDO, the kernel initializes against it (the COLLATERAL_ASSET
    ///         identity check passes), the composed price is live against the real CDO's virtual price + feed with
    ///         the deviation clock as its timestamp, the template-deployed BPT oracle is injected into the kernel's
    ///         liquidity venue, the pricing-admin selectors bind to ADMIN_ORACLE_ROLE, and the senior pool leg is
    ///         priced via the kernel
    function test_ExecuteMarketDeployment_IdleCDOOracleKernelWiring() external {
        _register();
        DayMarketConfig memory cfg = _marketConfig();
        bytes memory p = abi.encode(marketBuilder.buildMarketParams(cfg, MARKET_ID, address(factory), DEPLOYER));
        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        // The kernel initialized with the configured immutable adapter, which pins the REAL CDO and prices its AA tranche.
        assertEq(IRoycoDayKernel(r.kernel).getCollateralAssetOracle(), cfg.oracle.deployed, "kernel oracle != configured adapter");
        IdleCDOTranchePriceOracle oracle = IdleCDOTranchePriceOracle(cfg.oracle.deployed);
        assertEq(oracle.IDLE_CDO(), PARETO_FALCONX_CDO, "adapter CDO != configured CDO");
        assertEq(oracle.COLLATERAL_ASSET(), AA_TRANCHE_TOKEN, "adapter collateral != AA tranche");

        // The adapter is a direct immutable deployment: no proxy (the ERC1967 implementation slot is empty), the
        // deviation threshold is the configured construction immutable, and the clock's checkpoint pair is the
        // construction-time virtual price baseline plus the deployer-attested last update (now at deployment).
        assertEq(
            uint256(vm.load(address(oracle), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)), 0, "adapter must not be an ERC1967 proxy"
        );
        assertEq(oracle.MIN_DEVIATION_WAD(), MIN_DEVIATION_WAD, "adapter threshold != configured immutable");
        (uint160 clockValue, uint32 clockUpdatedAt) = oracle.getOracleClockState();
        assertEq(
            uint256(clockValue),
            IIdleCDO(PARETO_FALCONX_CDO).virtualPrice(AA_TRANCHE_TOKEN) * 10 ** (18 - IERC20Metadata(IIdleCDO(PARETO_FALCONX_CDO).token()).decimals()),
            "clock baseline != live virtual price in WAD"
        );
        assertEq(clockUpdatedAt, uint32(block.timestamp), "clock checkpoint != deployer-attested last update");

        // The composed price is live against the real CDO: the AA virtual price lifted from the underlying token's
        // decimals to WAD, times the real feed's answer lifted from feed decimals, floored in one mulDiv. The report's
        // timestamp is the OLDER of the deviation clock and the Chainlink leg, so a stale feed gates pricing even while
        // the virtual price keeps deviating. At this pinned block the USDC feed sits inside its heartbeat but behind the
        // clock, so the feed is the binding hop.
        uint256 virtualPriceWAD =
            IIdleCDO(PARETO_FALCONX_CDO).virtualPrice(AA_TRANCHE_TOKEN) * 10 ** (18 - IERC20Metadata(IIdleCDO(PARETO_FALCONX_CDO).token()).decimals());
        (, int256 answer,, uint256 feedUpdatedAt,) = AggregatorV3Interface(USDC_USD_FEED).latestRoundData();
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(
            NAV_UNIT.unwrap(price),
            virtualPriceWAD.mulDiv(uint256(answer), 10 ** AggregatorV3Interface(USDC_USD_FEED).decimals()),
            "composed price != CDO virtual price x feed"
        );
        (, uint32 reportClockUpdatedAt) = oracle.getOracleClockState();
        assertLt(feedUpdatedAt, reportClockUpdatedAt, "the feed must be the older hop at this pinned block");
        assertEq(updatedAt, feedUpdatedAt, "report timestamp must be the older of the deviation clock and the feed");
        assertEq(oracle.previewPoke(), updatedAt, "previewPoke must agree with getPrice's report timestamp");
        assertGt(NAV_UNIT.unwrap(price), 0.01e18, "composed price implausibly low");
        assertLt(NAV_UNIT.unwrap(price), 100e18, "composed price implausibly high");

        // The template deployed the BPT oracle through Balancer's E-CLP LP oracle factory and injected it into the
        // kernel's liquidity venue, overwriting the null placeholder in the params blob.
        address pool = IRoycoDayKernel(r.kernel).lptAsset();
        address bptOracle = BalancerV3LiquidityVenue(r.kernel).getBalancerV3LiquidityVenueState().bptOracle;
        assertTrue(bptOracle != address(0), "bptOracle unset");
        assertGt(bptOracle.code.length, 0, "bptOracle has no code");
        assertTrue(ILPOracleFactoryBase(ECLP_LP_ORACLE_FACTORY).isOracleFromFactory(ILPOracleBase(bptOracle)), "not from oracle factory");
        assertEq(address(LPOracleBase(bptOracle).pool()), pool, "oracle.pool() != market pool");

        // The four pricing-admin selectors resolve to ADMIN_ORACLE_ROLE on the market AM.
        assertEq(am.getTargetFunctionRole(r.kernel, IRoycoDayKernel.setCollateralAssetOracle.selector), ADMIN_ORACLE_ROLE, "setCollateralAssetOracle role");
        assertEq(am.getTargetFunctionRole(r.kernel, IRoycoDayKernel.setSequencerUptimeFeed.selector), ADMIN_ORACLE_ROLE, "setSequencerUptimeFeed role");
        assertEq(am.getTargetFunctionRole(r.kernel, BalancerV3LiquidityVenue.setBPTOracle.selector), ADMIN_ORACLE_ROLE, "setBPTOracle role");
        assertEq(
            am.getTargetFunctionRole(r.kernel, BalancerV3LiquidityVenue.setMaxReinvestmentSlippage.selector),
            ADMIN_ORACLE_ROLE,
            "setMaxReinvestmentSlippage role"
        );

        // The senior pool leg is WITH_RATE priced by the kernel and the quote leg is STANDARD.
        IVault vault = IVault(address(GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY).getVault()));
        (IERC20[] memory tokens, TokenInfo[] memory info,,) = vault.getPoolTokenInfo(pool);
        assertEq(tokens.length, 2, "pool token count");
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (address(tokens[i]) == r.seniorTranche) {
                assertTrue(info[i].tokenType == TokenType.WITH_RATE, "senior leg not WITH_RATE");
                assertEq(address(info[i].rateProvider), r.kernel, "senior rate provider != kernel");
            } else {
                assertTrue(info[i].tokenType == TokenType.STANDARD, "quote leg not STANDARD");
                assertEq(address(info[i].rateProvider), address(0), "quote leg has a rate provider");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GUARD (the adapter constructor rejects a non-tranche collateral against the REAL CDO)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The adapter refuses to price a collateral that is neither of the REAL CDO's tranche tokens: the CDO's
    ///         virtualPrice treats unknown addresses as the BB tranche, so the constructor guard is what stops a
    ///         mispointed market from silently pricing the wrong asset
    function test_RevertIf_CollateralIsNotACDOTranche() external {
        vm.expectRevert(IdleCDOTranchePriceOracle.COLLATERAL_ASSET_MUST_BE_CDO_TRANCHE.selector);
        new IdleCDOTranchePriceOracle(
            PARETO_FALCONX_CDO, SNUSD_VAULT, USDC_USD_FEED, MIN_DEVIATION_WAD, 0, FEED_STALENESS_THRESHOLD_SECONDS, CDO_PRICE_STALENESS_THRESHOLD_SECONDS
        );
    }
}
