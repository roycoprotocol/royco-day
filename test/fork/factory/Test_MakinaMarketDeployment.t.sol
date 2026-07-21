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
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { DeployScript } from "../../../script/Deploy.s.sol";
import {
    DeploymentResult,
    IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_QuoterKernelParams,
    KernelType,
    MarketConfig
} from "../../../script/config/DeploymentTypes.sol";
import { Create2DeployUtils } from "../../../script/utils/Create2DeployUtils.sol";
import { RoycoDayEntryPoint } from "../../../src/entrypoint/RoycoDayEntryPoint.sol";
import { ADMIN_ENTRY_POINT_ROLE, ADMIN_FACTORY_ROLE, ADMIN_ORACLE_QUOTER_ROLE, ADMIN_ROLE, DEPLOYER_ROLE, SYNC_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import {
    Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate
} from "../../../src/factory/templates/Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate.sol";
import { TAG_ST_PROXY } from "../../../src/factory/templates/base/Constants.sol";
import { BalancerV3_GyroECLP_LT_DeploymentTemplate } from "../../../src/factory/templates/liquidity-tranche/BalancerV3_GyroECLP_LT_DeploymentTemplate.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IMachine } from "../../../src/interfaces/external/makina/IMachine.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import {
    Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel
} from "../../../src/kernels/Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";

/// @title Test_MakinaMarketDeployment
/// @notice Fork test for the REAL Makina Day template
///         (`Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate`), modeled on
///         Test_RoycoFactory's direct-template pattern. Covers the deltas the golden ERC4626 suite cannot: the
///         machine address threading from `kernelSpecificParams` into the kernel constructor, the BPT oracle
///         injection on this kernel family, the ST/JT quoter selector role bindings, the senior pool leg's kernel
///         rate provider, and the atomic unwind when the machine's share token mismatches the ST asset.
/// @dev Requires a mainnet fork (real Balancer V3 + Gyro E-CLP + the REAL DUSD Makina machine). FAILS (env not
///      found) when `MAINNET_RPC_URL` is unset, instead of silently passing.
contract Test_MakinaMarketDeployment is Test {
    uint256 internal constant FORK_BLOCK = 25_400_000;
    address internal constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;
    address internal constant ECLP_LP_ORACLE_FACTORY = 0x301EDe5Fd4f9d7266B09c3A2E38F97776447154B;

    /// @notice DUSD on Ethereum mainnet
    address internal constant DUSD = 0x1e33E98aF620F1D563fcD3cfd3C75acE841204ef;

    /// @notice Makina machine for DUSD
    address internal constant MAKINA_MACHINE = 0x6b006870C83b1Cd49E766Ac9209f8d68763Df721;

    address internal constant SNUSD_VAULT = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313; // mismatched ST/JT asset for the revert test

    AccessManager internal am;
    RoycoFactory internal factory;
    DeployScript internal deployScript;
    Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate internal template;
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

        // The real Makina Day template, bound to this factory. `deployScript` externally deploys each market's
        // impls/YDMs/pool and pre-deploys its ST + hook proxies (`deployMarketContractsForTest`), then builds the
        // template params (`buildDayParams`). Its nested `deployDeterministicProxy` calls run with `msg.sender == address(deployScript)`,
        // so the deployScript must hold DEPLOYER_ROLE.
        deployScript = new DeployScript();
        am.grantRole(DEPLOYER_ROLE, address(deployScript), 0);
        template = new Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate(
            IRoycoFactory(address(factory)),
            GyroECLPPoolFactory(GYRO_ECLP_POOL_FACTORY),
            address(entryPoint),
            address(syncer)
        );
    }

    // ─── helpers ───

    function _register() internal {
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));
    }

    /// @dev Clones the snUSD market config in memory and swaps in the ST/JT asset plus the Makina kernel type +
    ///      params blob. No config file entry exists for this kernel yet, so the test IS the params source
    ///      (MarketDeploymentConfig untouched).
    function _marketConfig(address _machine, address _stJtAsset) internal view returns (MarketConfig memory cfg) {
        cfg = deployScript.getMarketConfig("snUSD");
        cfg.seniorAsset = _stJtAsset;
        cfg.juniorAsset = _stJtAsset;
        cfg.kernelType = KernelType.Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel;
        cfg.kernelSpecificParams = abi.encode(
            IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_QuoterKernelParams({
                makinaMachine: _machine,
                stAndJTQuoterParams: IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams({
                    // Admin-primary configuration: hardcode the accounting asset to NAV rate to WAD via the admin
                    // override (a nonzero stored rate with a null oracle passes the oracle-presence invariant)
                    initialConversionRateWAD: 1e18,
                    accountingAssetToNavAssetOracle: address(0),
                    stalenessThresholdSeconds: 0,
                    sequencerUptimeFeed: address(0),
                    gracePeriodSeconds: 0
                }),
                ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({
                    bptOracle: address(0), // deployed by the template after the pool is created, overwritten by it
                    maxReinvestmentSlippageWAD: 0.001e18
                })
            })
        );
    }

    function _encodedParams(bytes32 _marketId, address _machine, address _stJtAsset) internal returns (bytes memory) {
        MarketConfig memory cfg = _marketConfig(_machine, _stJtAsset);
        BalancerV3_GyroECLP_LT_DeploymentTemplate.MarketContracts memory mc =
            deployScript.deployMarketContractsForTest(cfg, _marketId, factory, address(template), address(am));
        return abi.encode(deployScript.buildDayParams(cfg, _marketId, PROTOCOL_FEE_RECIPIENT, address(0), mc));
    }

    function _deploy(bytes32 _marketId) internal returns (IRoycoProtocolTemplate.DeploymentResult memory) {
        // Precompute the params first: `_encodedParams` externally deploys the market contracts as `deployScript`,
        // which would otherwise consume the `vm.prank(DEPLOYER)` intended for `executeMarketDeployment`.
        bytes memory p = _encodedParams(_marketId, MAKINA_MACHINE, DUSD);
        vm.prank(DEPLOYER);
        return factory.executeMarketDeployment(address(template), p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT WIRING (the Makina-specific deltas)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The template threads the REAL machine address from `kernelSpecificParams` into the kernel constructor,
    ///         quotes a live composed rate off the machine's real share price, injects its template-deployed BPT
    ///         oracle into the kernel quoter, binds the ST/JT quoter admin selectors to ADMIN_ORACLE_QUOTER_ROLE, and
    ///         prices the senior pool leg via the kernel
    function test_ExecuteMarketDeployment_MakinaKernelWiring() external {
        _register();
        IRoycoProtocolTemplate.DeploymentResult memory r = _deploy(MARKET_ID);

        // The kernel proxy pinned the REAL machine as its constructor immutable.
        assertEq(
            Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel(r.kernel).MAKINA_MACHINE(),
            MAKINA_MACHINE,
            "kernel MAKINA_MACHINE != configured machine"
        );

        // The composed quoter rate is live against the real machine. The stored accounting asset to NAV rate is WAD,
        // so the composed rate collapses to the machine's real share price scaled to WAD by the decimals probe
        // (the quoter's mulDiv by the stored WAD rate is the identity).
        uint256 probe = 10 ** (18 + IERC20Metadata(DUSD).decimals() - IERC20Metadata(IMachine(MAKINA_MACHINE).accountingToken()).decimals());
        uint256 rate = IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter(r.kernel).getTrancheUnitToNAVUnitConversionRateWAD();
        assertEq(rate, IMachine(MAKINA_MACHINE).convertToAssets(probe), "composed rate != machine share price");
        assertGt(rate, 0.01e18, "composed rate implausibly low");
        assertLt(rate, 100e18, "composed rate implausibly high");

        // The template deployed the BPT oracle through Balancer's E-CLP LP oracle factory and injected it into the
        // kernel quoter, overwriting the null placeholder in the params blob.
        address pool = IRoycoDayKernel(r.kernel).LT_ASSET();
        address bptOracle = BalancerV3_LT_BPTOracle_Quoter(r.kernel).getBalancerV3QuoterState().bptOracle;
        assertTrue(bptOracle != address(0), "bptOracle unset");
        assertGt(bptOracle.code.length, 0, "bptOracle has no code");
        assertTrue(ILPOracleFactoryBase(ECLP_LP_ORACLE_FACTORY).isOracleFromFactory(ILPOracleBase(bptOracle)), "not from oracle factory");
        assertEq(address(LPOracleBase(bptOracle).pool()), pool, "oracle.pool() != market pool");

        // The three ST/JT quoter admin selectors resolve to ADMIN_ORACLE_QUOTER_ROLE on the market AM.
        assertEq(am.getTargetFunctionRole(r.kernel, bytes4(keccak256("setConversionRate(uint256,bool)"))), ADMIN_ORACLE_QUOTER_ROLE, "setConversionRate role");
        assertEq(
            am.getTargetFunctionRole(r.kernel, bytes4(keccak256("setChainlinkOracle(address,uint48,bool)"))),
            ADMIN_ORACLE_QUOTER_ROLE,
            "setChainlinkOracle role"
        );
        assertEq(
            am.getTargetFunctionRole(r.kernel, bytes4(keccak256("setSequencerUptimeFeed(address,uint48)"))),
            ADMIN_ORACLE_QUOTER_ROLE,
            "setSequencerUptimeFeed role"
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
    // REVERT UNWIND (the kernel constructor guard fails the whole deployment atomically)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The REAL machine's share token (DUSD) mismatches a market whose ST asset is the snUSD vault, failing
    ///         the kernel constructor's TRANCHE_ASSET_MUST_BE_MACHINE_SHARE guard. Under the split deployment flow the
    ///         kernel implementation is deployed EXTERNALLY (in `deployMarketContractsForTest`) before the wiring
    ///         transaction, so the mismatch now aborts there: the CREATE2 factory surfaces the constructor revert as a
    ///         failed deployment, and the whole external call unwinds atomically — no market contracts, no registry entries
    function test_RevertIf_MachineShareTokenMismatchesSTAsset_DeploymentUnwindsAtomically() external {
        _register();

        bytes32 marketId = MARKET_ID;
        // The REAL machine against the WRONG ST asset (the snUSD vault, not the machine's DUSD share token).
        MarketConfig memory cfg = _marketConfig(MAKINA_MACHINE, SNUSD_VAULT);
        address predictedST = factory.predictDeterministicAddress(keccak256(abi.encodePacked("ROYCO_MARKET_", marketId, TAG_ST_PROXY)));

        // The canonical CREATE2 deployer swallows the kernel quoter's constructor revert reason, so the failure
        // surfaces as `DeploymentFailed` with empty return data
        vm.expectRevert(abi.encodeWithSelector(Create2DeployUtils.DeploymentFailed.selector, bytes("")));
        deployScript.deployMarketContractsForTest(cfg, marketId, factory, address(template), address(am));

        // Atomic unwind: nothing was deployed or registered.
        assertEq(predictedST.code.length, 0, "no tranche deployed");
        assertEq(factory.trancheToKernel(predictedST), address(0), "no registry entry");
    }
}
