// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ILPOracleBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleBase.sol";
import { ILPOracleFactoryBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { TokenInfo, TokenType } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { LPOracleBase } from "../../../lib/balancer-v3-monorepo/pkg/oracles/contracts/LPOracleBase.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { Test } from "../../../lib/forge-std/src/Test.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactoryGatekeeper } from "../../../src/factory/RoycoFactoryGatekeeper.sol";
import { DayMarketRegistry } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketRegistry.sol";
import { DayMarketConfig } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketTypes.sol";
import { DeployMarketComponent } from "../../../script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol";
import { FactoryScaffold } from "../../utils/FactoryScaffold.sol";
import { TemplateScaffold } from "../../utils/TemplateScaffold.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { ADMIN_ENTRY_POINT_ROLE, ADMIN_FACTORY_ROLE, ADMIN_ORACLE_ROLE, SYNC_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { TAG_KERNEL_PROXY } from "../../../src/factory/templates/base/Constants.sol";
import {
    RoycoDayBalancerV3MarketDeploymentTemplate
} from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { AggregatorV3Interface } from "../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { BalancerV3LiquidityVenue } from "../../../src/kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import { NAV_UNIT } from "../../../src/libraries/Units.sol";
import { ChainlinkPriceOracle } from "../../../src/oracle/ChainlinkPriceOracle.sol";

/// @title Test_ChainlinkOracleMarketDeployment
/// @notice Fork test for the single Day template (`RoycoDayBalancerV3MarketDeploymentTemplate`) deployed against a
///         market priced by the identity-hop `ChainlinkPriceOracle` adapter, modeled on Test_RoycoFactory's
///         direct-template pattern. Covers the deltas the golden ERC4626 suite cannot: the collateral asset oracle
///         threading from `MarketParams` into the kernel init, the identity-hop price composition against the real
///         feed, the pricing-admin selector role bindings, and the atomic unwind when the oracle prices a different
///         collateral asset than the market's.
/// @dev Reuses the snUSD asset + RedStone feed addresses: the kernel accepts any collateral whose oracle passes the
///      COLLATERAL_ASSET identity check, and the feed serves as the live Chainlink-compatible NAV leg. Requires a
///      mainnet fork. FAILS (env not found) when `MAINNET_RPC_URL` is unset, instead of silently passing.
contract Test_ChainlinkOracleMarketDeployment is Test {
    /// @dev The address that supplies each market's genesis pool liquidity in this suite
    uint256 internal constant FORK_BLOCK = 25_400_000;
    address internal constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;
    address internal constant ECLP_LP_ORACLE_FACTORY = 0x301EDe5Fd4f9d7266B09c3A2E38F97776447154B;
    address internal constant NUSD_REDSTONE_ORACLE = 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95; // collateral->NAV feed (identity hop)
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // mismatched oracle collateral for the revert test

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
    }

    // ─── helpers ───

    function _register() internal {
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));
    }

    /// @dev Clones the snUSD market config in memory and swaps in the identity-hop Chainlink oracle: the market's
    ///      collateral is priced directly by the feed instead of through the config's ERC4626 share-price adapter.
    ///      The direct-template path must supply the deployed oracle itself (the `deploy()` flow resolves it).
    function _marketConfig(address _oracleCollateralAsset) internal returns (DayMarketConfig memory cfg) {
        cfg = registry.getDayMarketConfig("snUSD");
        cfg.oracle.deployed = address(new ChainlinkPriceOracle(_oracleCollateralAsset, NUSD_REDSTONE_ORACLE, 48 hours));
        _resolveYdms(cfg);
        _fundPoolSeed(cfg);
    }

    /// @dev Resolves (or deploys) the market's yield distribution model instances, mirroring the pipeline
    function _resolveYdms(DayMarketConfig memory _cfg) internal {
        if (_cfg.accountant.jtYdm.deployed == address(0)) _cfg.accountant.jtYdm.deployed = marketBuilder.deployYDM("JT model  ", _cfg.accountant.jtYdm);
        if (_cfg.accountant.lptYdm.deployed == address(0)) _cfg.accountant.lptYdm.deployed = marketBuilder.deployYDM("LPT model ", _cfg.accountant.lptYdm);
    }

    /// @dev Every market is deployed with genesis pool liquidity pulled from the deployment caller (the pranked
    ///      DEPLOYER), so it must hold the quote and have approved the template before `executeMarketDeployment`
    function _fundPoolSeed(DayMarketConfig memory _cfg) internal {
        deal(_cfg.pool.quoteAsset, DEPLOYER, _cfg.poolInitialization.quoteAmount);
        vm.prank(DEPLOYER);
        IERC20(_cfg.pool.quoteAsset).approve(address(template), _cfg.poolInitialization.quoteAmount);
    }


    function _encodedParams(bytes32 _marketId, address _oracleCollateralAsset) internal returns (bytes memory) {
        DayMarketConfig memory cfg = _marketConfig(_oracleCollateralAsset);
        return abi.encode(marketBuilder.buildMarketParams(cfg, _marketId, address(factory), DEPLOYER));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT WIRING (the Chainlink-identity-oracle deltas)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The template threads the configured `ChainlinkPriceOracle` from `MarketParams` into the kernel init, the
    ///         identity-hop price composes exactly to the real feed's answer lifted to WAD, the template-deployed BPT
    ///         oracle is injected into the kernel's liquidity venue, the pricing-admin selectors bind to
    ///         ADMIN_ORACLE_ROLE, and the senior pool leg is priced via the kernel
    function test_ExecuteMarketDeployment_ChainlinkOracleKernelWiring() external {
        _register();
        DayMarketConfig memory cfg = _marketConfig(registry.getDayMarketConfig("snUSD").collateralAsset);
        bytes memory p = abi.encode(marketBuilder.buildMarketParams(cfg, MARKET_ID, address(factory), DEPLOYER));
        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        // The kernel initialized with the configured identity-hop oracle, which passes the COLLATERAL_ASSET check.
        assertEq(IRoycoDayKernel(r.kernel).getCollateralAssetOracle(), cfg.oracle.deployed, "kernel oracle != configured adapter");
        assertEq(ChainlinkPriceOracle(cfg.oracle.deployed).COLLATERAL_ASSET(), cfg.collateralAsset, "oracle collateral != market collateral");

        // The identity hop composes to exactly the real feed's answer lifted from feed decimals to WAD, and the feed's
        // update timestamp passes through unchanged.
        (, int256 answer,, uint256 feedUpdatedAt,) = AggregatorV3Interface(NUSD_REDSTONE_ORACLE).latestRoundData();
        (NAV_UNIT price, uint256 updatedAt) = ChainlinkPriceOracle(cfg.oracle.deployed).getPrice();
        assertEq(NAV_UNIT.unwrap(price), uint256(answer) * 1e18 / 10 ** AggregatorV3Interface(NUSD_REDSTONE_ORACLE).decimals(), "identity-hop price");
        assertEq(updatedAt, feedUpdatedAt, "feed timestamp must pass through");

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
    // REVERT UNWIND (the kernel init oracle-identity guard fails the whole deployment atomically)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice An oracle pricing a DIFFERENT collateral asset (USDC) than the market's (the snUSD vault) fails the
    ///         kernel init's COLLATERAL_ASSET_ORACLE_MISMATCH guard inside the wiring transaction: the kernel proxy's
    ///         CREATE3 deployment fails and the whole `executeMarketDeployment` unwinds atomically — no kernel proxy,
    ///         no registry entries
    function test_RevertIf_OracleCollateralMismatchesMarketCollateral_DeploymentUnwindsAtomically() external {
        _register();

        // The identity oracle prices USDC, the market's collateral stays the snUSD vault.
        bytes memory p = _encodedParams(MARKET_ID, MAINNET_USDC);
        address predictedKernel = factory.predictDeterministicAddress(keccak256(abi.encodePacked("ROYCO_MARKET_", MARKET_ID, TAG_KERNEL_PROXY)));

        // The CREATE3 deployer surfaces the kernel init's revert as a failed deterministic deployment.
        vm.prank(DEPLOYER);
        vm.expectRevert(bytes4(keccak256("DeploymentFailed()")));
        factory.executeMarketDeployment(address(template), p);

        // Atomic unwind: the wiring transaction's kernel proxy and registry entries are gone.
        assertEq(predictedKernel.code.length, 0, "no kernel deployed");
        assertEq(factory.trancheToKernel(predictedKernel), address(0), "no registry entry");
    }
}
