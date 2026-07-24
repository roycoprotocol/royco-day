// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ILPOracleBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleBase.sol";
import { ILPOracleFactoryBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { TokenInfo, TokenType } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { LPOracleBase } from "../../../lib/balancer-v3-monorepo/pkg/oracles/contracts/LPOracleBase.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { DeployScript } from "../../../script/Deploy.s.sol";
import { MarketConfig } from "../../../script/config/DeploymentTypes.sol";
import { RoycoDayEntryPoint } from "../../../src/entrypoint/RoycoDayEntryPoint.sol";
import { ADMIN_ENTRY_POINT_ROLE, ADMIN_FACTORY_ROLE, ADMIN_ORACLE_ROLE, ADMIN_ROLE, DEPLOYER_ROLE, SYNC_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import {
    RoycoDayBalancerV3MarketDeploymentTemplate
} from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { AggregatorV3Interface } from "../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IIdleCDO } from "../../../src/interfaces/external/idle-finance/IIdleCDO.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { BalancerV3LiquidityVenue } from "../../../src/kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import { NAV_UNIT } from "../../../src/libraries/Units.sol";
import { IdleCDOTranchePriceOracle } from "../../../src/oracle/IdleCDOTranchePriceOracle.sol";

/// @title Test_IdleCDOMarketDeployment
/// @notice Fork test for the single Day template (`RoycoDayBalancerV3MarketDeploymentTemplate`) deployed against a
///         market whose collateral is a REAL Idle CDO AA tranche priced by the proxied `IdleCDOTranchePriceOracle`
///         adapter, modeled on Test_RoycoFactory's direct-template pattern. Covers the deltas the golden ERC4626
///         suite cannot: the proxied adapter's CDO threading + tranche-identity guard, the live virtual-price
///         composition against the real CDO + feed, the deviation-clock timestamp seam, the BPT oracle injection,
///         the pricing-admin selector role bindings, and the senior pool leg's kernel rate provider.
/// @dev Requires a mainnet fork (real Balancer V3 + Gyro E-CLP + the REAL Pareto Idle CDO). FAILS (env not
///      found) when `MAINNET_RPC_URL` is unset, instead of silently passing.
contract Test_IdleCDOMarketDeployment is Test {
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

    /// @dev The deviation-clock threshold the proxied adapter is initialized with (0.1%)
    uint256 internal constant MIN_DEVIATION_WAD = 0.001e18;

    address internal constant SNUSD_VAULT = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313; // non-tranche collateral for the guard test

    AccessManager internal am;
    RoycoFactory internal factory;
    DeployScript internal deployScript;
    RoycoDayBalancerV3MarketDeploymentTemplate internal template;
    IRoycoDayEntryPoint internal entryPoint;
    RoycoMarketSyncer internal syncer;

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
        am = new AccessManager(address(this));

        // OZ mandates init data in the ERC1967Proxy constructor, and `initialize` requires the factory to already
        // hold ADMIN_ROLE on the AM. So deploy the proxy via CREATE2: predict the salted address, grant it
        // ADMIN_ROLE, then construct the proxy with real init data. (A salt-based prediction is nonce-independent,
        // the golden suite's CREATE-nonce prediction drifts after createSelectFork on current foundry.)
        RoycoFactory impl = new RoycoFactory();
        bytes memory factoryInitData = abi.encodeCall(RoycoFactory.initialize, (address(am)));
        bytes32 proxySalt = keccak256("FACTORY_PROXY");
        address predicted = vm.computeCreate2Address(
            proxySalt, keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(impl), factoryInitData))), address(this)
        );
        am.grantRole(ADMIN_ROLE, predicted, 0);
        factory = RoycoFactory(address(new ERC1967Proxy{ salt: proxySalt }(address(impl), factoryInitData)));
        require(address(factory) == predicted, "proxy address prediction failed");

        // Grant the factory-facing roles the initialize() call bound to selectors.
        am.grantRole(ADMIN_FACTORY_ROLE, FACTORY_ADMIN, 0);
        am.grantRole(DEPLOYER_ROLE, DEPLOYER, 0);

        // The REAL periphery singletons the template configures per market: the entry point (initialized empty,
        // configs flow through the factory) and the market syncer (initialized with no kernels).
        RoycoDayEntryPoint entryPointImpl = new RoycoDayEntryPoint(address(factory));
        entryPoint = IRoycoDayEntryPoint(
            address(
                new ERC1967Proxy(
                    address(entryPointImpl), abi.encodeCall(RoycoDayEntryPoint.initialize, (new address[](0), new IRoycoDayEntryPoint.TrancheConfig[](0)))
                )
            )
        );
        RoycoMarketSyncer syncerImpl = new RoycoMarketSyncer();
        syncer =
            RoycoMarketSyncer(address(new ERC1967Proxy(address(syncerImpl), abi.encodeCall(RoycoMarketSyncer.initialize, (address(am), new address[](0))))));

        // Bind the config selectors the factory drives during deployments (the factory self-granted
        // ADMIN_ENTRY_POINT_ROLE + SYNC_ROLE in its initialize).
        bytes4[] memory entryPointSelectors = new bytes4[](1);
        entryPointSelectors[0] = IRoycoDayEntryPoint.modifyTrancheConfigs.selector;
        am.setTargetFunctionRole(address(entryPoint), entryPointSelectors, ADMIN_ENTRY_POINT_ROLE);
        bytes4[] memory syncerSelectors = new bytes4[](1);
        syncerSelectors[0] = RoycoMarketSyncer.addMarketKernels.selector;
        am.setTargetFunctionRole(address(syncer), syncerSelectors, SYNC_ROLE);

        // The real Day template, bound to this factory. `deployScript` externally deploys each market's impls/YDMs/pool
        // and pre-deploys its ST + hook proxies (`deployMarketContractsForTest`), then builds the template params
        // (`buildMarketParams`). Its nested `deployDeterministicProxy` calls run with `msg.sender == address(deployScript)`,
        // so the deployScript must hold DEPLOYER_ROLE.
        deployScript = new DeployScript();
        am.grantRole(DEPLOYER_ROLE, address(deployScript), 0);
        template = new RoycoDayBalancerV3MarketDeploymentTemplate(
            IRoycoFactory(address(factory)), GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY), address(entryPoint), address(syncer)
        );
    }

    // ─── helpers ───

    function _register() internal {
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));
    }

    /// @dev Deploys the proxied Idle CDO tranche oracle the production script deploys: the impl pins the CDO + tranche +
    ///      feed as immutables and the ERC1967 proxy initializes the deviation clock (mirrors `_deployIdleCDOTranchePriceOracle`).
    function _deployIdleOracle(address _tranche) internal returns (address oracle) {
        IdleCDOTranchePriceOracle oracleImpl = new IdleCDOTranchePriceOracle(PARETO_FALCONX_CDO, _tranche, USDC_USD_FEED);
        // The attested last update is now: the deployer vouches the virtual price is current at deployment.
        return address(
            new ERC1967Proxy(
                address(oracleImpl), abi.encodeCall(IdleCDOTranchePriceOracle.initialize, (address(am), MIN_DEVIATION_WAD, uint32(block.timestamp)))
            )
        );
    }

    /// @dev Clones the snUSD market config in memory and swaps in the CDO AA tranche collateral + its proxied
    ///      virtual-price oracle. The direct-template path must supply the deployed oracle itself (the `deploy()` flow resolves it).
    function _marketConfig() internal returns (MarketConfig memory cfg) {
        cfg = deployScript.getMarketConfig("snUSD");
        cfg.collateralAsset = AA_TRANCHE_TOKEN;
        cfg.collateralAssetOracle = _deployIdleOracle(AA_TRANCHE_TOKEN);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT WIRING (the Idle-CDO-specific deltas)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The proxied adapter pins the REAL CDO, the kernel initializes against it (the COLLATERAL_ASSET
    ///         identity check passes), the composed price is live against the real CDO's virtual price + feed with
    ///         the deviation clock as its timestamp, the template-deployed BPT oracle is injected into the kernel's
    ///         liquidity venue, the pricing-admin selectors bind to ADMIN_ORACLE_ROLE, and the senior pool leg is
    ///         priced via the kernel
    function test_ExecuteMarketDeployment_IdleCDOOracleKernelWiring() external {
        _register();
        MarketConfig memory cfg = _marketConfig();
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketContracts memory mc =
            deployScript.deployMarketContractsForTest(cfg, MARKET_ID, factory, address(template), address(am));
        bytes memory p = abi.encode(deployScript.buildMarketParams(cfg, MARKET_ID, PROTOCOL_FEE_RECIPIENT, address(0), mc));
        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        // The kernel initialized with the configured proxied adapter, which pins the REAL CDO and prices its AA tranche.
        assertEq(IRoycoDayKernel(r.kernel).getCollateralAssetOracle(), cfg.collateralAssetOracle, "kernel oracle != configured adapter");
        IdleCDOTranchePriceOracle oracle = IdleCDOTranchePriceOracle(cfg.collateralAssetOracle);
        assertEq(oracle.IDLE_CDO(), PARETO_FALCONX_CDO, "adapter CDO != configured CDO");
        assertEq(oracle.COLLATERAL_ASSET(), AA_TRANCHE_TOKEN, "adapter collateral != AA tranche");

        // The composed price is live against the real CDO: the AA virtual price lifted from the underlying token's
        // decimals to WAD, times the real feed's answer lifted from feed decimals, floored in one mulDiv. The report's
        // timestamp is the deviation clock's, NOT the feed's (the virtual price is what gates staleness).
        uint256 virtualPriceWAD =
            IIdleCDO(PARETO_FALCONX_CDO).virtualPrice(AA_TRANCHE_TOKEN) * 10 ** (18 - IERC20Metadata(IIdleCDO(PARETO_FALCONX_CDO).token()).decimals());
        (, int256 answer,,,) = AggregatorV3Interface(USDC_USD_FEED).latestRoundData();
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(
            NAV_UNIT.unwrap(price),
            virtualPriceWAD.mulDiv(uint256(answer), 10 ** AggregatorV3Interface(USDC_USD_FEED).decimals()),
            "composed price != CDO virtual price x feed"
        );
        assertEq(updatedAt, oracle.previewPoke(), "report timestamp must be the deviation clock's");
        assertGt(NAV_UNIT.unwrap(price), 0.01e18, "composed price implausibly low");
        assertLt(NAV_UNIT.unwrap(price), 100e18, "composed price implausibly high");

        // The template deployed the BPT oracle through Balancer's E-CLP LP oracle factory and injected it into the
        // kernel's liquidity venue, overwriting the null placeholder in the params blob.
        address pool = IRoycoDayKernel(r.kernel).LPT_ASSET();
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
        new IdleCDOTranchePriceOracle(PARETO_FALCONX_CDO, SNUSD_VAULT, USDC_USD_FEED);
    }
}
