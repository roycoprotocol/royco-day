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
import { TAG_KERNEL_PROXY } from "../../../src/factory/templates/base/Constants.sol";
import {
    RoycoDayBalancerV3MarketDeploymentTemplate
} from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { AggregatorV3Interface } from "../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IMachine } from "../../../src/interfaces/external/makina/IMachine.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { BalancerV3LiquidityVenue } from "../../../src/kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import { NAV_UNIT } from "../../../src/libraries/Units.sol";
import { MakinaSharePriceOracle } from "../../../src/oracle/MakinaSharePriceOracle.sol";

/// @title Test_MakinaMarketDeployment
/// @notice Fork test for the single Day template (`RoycoDayBalancerV3MarketDeploymentTemplate`) deployed against a
///         market whose collateral is a REAL Makina machine share priced by the `MakinaSharePriceOracle` adapter,
///         modeled on Test_RoycoFactory's direct-template pattern. Covers the deltas the golden ERC4626 suite cannot:
///         the machine share resolved as the adapter's collateral, the live share-price composition against the real
///         machine + feed, the BPT oracle injection, the pricing-admin selector role bindings, the senior pool leg's
///         kernel rate provider, and the atomic unwind when the machine's share token mismatches the market collateral.
/// @dev Requires a mainnet fork (real Balancer V3 + Gyro E-CLP + the REAL DUSD Makina machine). FAILS (env not
///      found) when `MAINNET_RPC_URL` is unset, instead of silently passing.
contract Test_MakinaMarketDeployment is Test {
    using Math for uint256;

    uint256 internal constant FORK_BLOCK = 25_400_000;
    address internal constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;
    address internal constant ECLP_LP_ORACLE_FACTORY = 0x301EDe5Fd4f9d7266B09c3A2E38F97776447154B;

    /// @notice DUSD on Ethereum mainnet
    address internal constant DUSD = 0x1e33E98aF620F1D563fcD3cfd3C75acE841204ef;

    /// @notice Makina machine for DUSD
    address internal constant MAKINA_MACHINE = 0x6b006870C83b1Cd49E766Ac9209f8d68763Df721;

    /// @notice Chainlink USDC / USD feed, the accounting-asset->NAV leg of the composed oracle
    address internal constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    address internal constant SNUSD_VAULT = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313; // mismatched collateral for the revert test

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

    /// @dev Clones the snUSD market config in memory and swaps in the Makina collateral + its share-price oracle.
    ///      The direct-template path must supply the deployed oracle itself (the `deploy()` flow resolves it).
    function _marketConfig(address _machine, address _collateralAsset) internal returns (MarketConfig memory cfg) {
        cfg = deployScript.getMarketConfig("snUSD");
        cfg.collateralAsset = _collateralAsset;
        cfg.collateralAssetOracle = address(new MakinaSharePriceOracle(_machine, USDC_USD_FEED));
    }

    function _encodedParams(bytes32 _marketId, address _machine, address _collateralAsset) internal returns (bytes memory) {
        MarketConfig memory cfg = _marketConfig(_machine, _collateralAsset);
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketContracts memory mc =
            deployScript.deployMarketContractsForTest(cfg, _marketId, factory, address(template), address(am));
        return abi.encode(deployScript.buildMarketParams(cfg, _marketId, PROTOCOL_FEE_RECIPIENT, address(0), mc));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT WIRING (the Makina-specific deltas)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The adapter resolves the REAL machine's share token as its collateral, the kernel initializes against
    ///         it (the COLLATERAL_ASSET identity check passes), the composed price is live against the real machine
    ///         and feed, the template-deployed BPT oracle is injected into the kernel's liquidity venue, the
    ///         pricing-admin selectors bind to ADMIN_ORACLE_ROLE, and the senior pool leg is priced via the kernel
    function test_ExecuteMarketDeployment_MakinaOracleKernelWiring() external {
        _register();
        MarketConfig memory cfg = _marketConfig(MAKINA_MACHINE, DUSD);
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketContracts memory mc =
            deployScript.deployMarketContractsForTest(cfg, MARKET_ID, factory, address(template), address(am));
        bytes memory p = abi.encode(deployScript.buildMarketParams(cfg, MARKET_ID, PROTOCOL_FEE_RECIPIENT, address(0), mc));
        vm.prank(DEPLOYER);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(template), p);

        // The kernel initialized with the configured adapter, whose collateral is the machine's real share token.
        assertEq(IRoycoDayKernel(r.kernel).getCollateralAssetOracle(), cfg.collateralAssetOracle, "kernel oracle != configured adapter");
        MakinaSharePriceOracle oracle = MakinaSharePriceOracle(cfg.collateralAssetOracle);
        assertEq(oracle.MAKINA_MACHINE(), MAKINA_MACHINE, "adapter machine != configured machine");
        assertEq(oracle.COLLATERAL_ASSET(), DUSD, "adapter collateral != machine share token");

        // The composed price is live against the real machine: the machine's share price scaled to WAD by the
        // decimals probe, times the real feed's answer lifted from feed decimals, floored in one mulDiv.
        uint256 probe = 10 ** (18 + IERC20Metadata(DUSD).decimals() - IERC20Metadata(IMachine(MAKINA_MACHINE).accountingToken()).decimals());
        (, int256 answer,, uint256 feedUpdatedAt,) = AggregatorV3Interface(USDC_USD_FEED).latestRoundData();
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(
            NAV_UNIT.unwrap(price),
            IMachine(MAKINA_MACHINE).convertToAssets(probe).mulDiv(uint256(answer), 10 ** AggregatorV3Interface(USDC_USD_FEED).decimals()),
            "composed price != machine share price x feed"
        );
        assertEq(updatedAt, feedUpdatedAt, "feed timestamp must pass through");
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
    // REVERT UNWIND (the kernel init oracle-identity guard fails the whole deployment atomically)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The REAL machine's share token (DUSD) mismatches a market whose collateral is the snUSD vault, failing
    ///         the kernel init's COLLATERAL_ASSET_ORACLE_MISMATCH guard inside the wiring transaction: the kernel
    ///         proxy's CREATE3 deployment fails and the whole `executeMarketDeployment` unwinds atomically — no kernel
    ///         proxy, no registry entries
    function test_RevertIf_MachineShareTokenMismatchesCollateral_DeploymentUnwindsAtomically() external {
        _register();

        // The REAL machine's adapter (collateral DUSD) against the WRONG market collateral (the snUSD vault).
        bytes memory p = _encodedParams(MARKET_ID, MAKINA_MACHINE, SNUSD_VAULT);
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
