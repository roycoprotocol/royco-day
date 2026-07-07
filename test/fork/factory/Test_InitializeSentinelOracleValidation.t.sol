// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { DeployScript } from "../../../script/Deploy.s.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel as DayKernel
} from "../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";

import {
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter as STJTChainlinkQuoter
} from "../../../src/kernels/base/quoter/identical-st-jt/IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import {
    IdenticalAssets_ST_JT_ChainlinkOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { RoycoDayTestBase } from "../../utils/RoycoDayTestBase.sol";

/**
 * @title InitializeSentinelOracleValidationTest
 * @notice Tests the deployment-time check added to the ST/JT Chainlink quoter's combined initializer
 *         (`IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter`): when the stored conversion rate is the
 *         sentinel, the market prices from the Chainlink oracle, so `initialize` requires a non-null oracle with a
 *         positive staleness threshold. A market that prices from an administrator-set rate must still deploy and run
 *         with a null oracle.
 * @dev Forks mainnet and deploys the real snUSD Day market once through `DeployScript` (as `DayMarketDeploymentTest`
 *      does), then reuses that market's kernel implementation and BPT oracle to spin up fresh, separately configured
 *      kernel proxies whose `initialize` is exercised with varied ST/JT quoter parameters. The installed OZ
 *      `ERC1967Proxy` initializes in its constructor, so each fresh proxy is deployed with the `initialize` calldata
 *      and a rejected configuration reverts the `new` itself. Requires `MAINNET_RPC_URL`.
 */
contract Test_InitializeSentinelOracleValidation is RoycoDayTestBase {
    // ── Real mainnet addresses (snUSD market) ────────────────────────────────────────────────────────────────────
    address internal constant NUSD_REDSTONE_ORACLE = 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95; // base->NAV feed
    address internal constant FACTORY_ADMIN = 0x7c405bbD131e42af506d14e752f2e59B19D49997; // ROOT_MULTISIG

    // ERC-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint48 internal constant STALENESS_48H = 48 hours; // a positive staleness threshold
    uint256 internal constant ADMIN_RATE_WAD = 1e18; // a non-sentinel administrator-set conversion rate
    uint64 internal constant LT_SLIPPAGE_WAD = 0.001e18; // the snUSD market's reinvestment slippage gate (valid: < WAD)

    // Reused from the once-deployed snUSD market so every fresh proxy shares valid kernel immutables and a valid LT config.
    address internal KERNEL_IMPL;
    address internal BPT_ORACLE;

    function _forkConfiguration() internal view override returns (uint256 forkBlock, string memory forkRpcUrl) {
        // No skip: the suite FAILS (env not found) when MAINNET_RPC_URL is unset, instead of silently passing.
        forkRpcUrl = vm.envString("MAINNET_RPC_URL");
        forkBlock = vm.envOr("FORK_BLOCK", uint256(25_400_000));
    }

    function setUp() public {
        // Fork mainnet + create wallets + `new DeployScript()`.
        _setUpRoyco();

        // Deploy the real snUSD Day market end to end so a valid kernel implementation and BPT oracle exist to reuse.
        DeployScript.DeploymentResult memory result = DEPLOY_SCRIPT.deploy(
            DEPLOY_SCRIPT.getMarketConfig("snUSD"), FACTORY_ADMIN, PROTOCOL_FEE_RECIPIENT_ADDRESS, 0, _generateRoleAssignments(), DEPLOYER.privateKey
        );
        _setDeployedMarket(result);

        // The kernel proxy points at the implementation whose immutables (tranches, assets, pool, vault) are all valid;
        // fresh proxies over it can be initialized once each with different ST/JT quoter parameters.
        KERNEL_IMPL = address(uint160(uint256(vm.load(address(KERNEL), ERC1967_IMPLEMENTATION_SLOT))));
        assertGt(KERNEL_IMPL.code.length, 0, "kernel implementation has no code");

        // Reuse the template-deployed BPT oracle so the LT quoter leg of `initialize` also succeeds in the success cases.
        BPT_ORACLE = BalancerV3_LT_BPTOracle_Quoter(address(KERNEL)).getBalancerV3QuoterState().bptOracle;
        assertTrue(BPT_ORACLE != address(0), "bpt oracle unset");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // Sentinel stored rate: initialize must reject an unusable oracle
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice A sentinel stored rate with a null oracle (and a positive threshold) reverts at initialize.
    function test_initialize_revertsForSentinelRateWithNullOracle() public {
        bytes memory initData = _encodeInitCall(0, address(0), STALENESS_48H);
        vm.expectRevert(STJTChainlinkQuoter.SENTINEL_RATE_REQUIRES_CHAINLINK_ORACLE.selector);
        new ERC1967Proxy(KERNEL_IMPL, initData);
    }

    /// @notice A sentinel stored rate with a set oracle but a zero staleness threshold reverts at initialize.
    function test_initialize_revertsForSentinelRateWithZeroThreshold() public {
        bytes memory initData = _encodeInitCall(0, NUSD_REDSTONE_ORACLE, 0);
        vm.expectRevert(STJTChainlinkQuoter.SENTINEL_RATE_REQUIRES_CHAINLINK_ORACLE.selector);
        new ERC1967Proxy(KERNEL_IMPL, initData);
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // Valid configurations: initialize must succeed
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice An administrator-set (non-sentinel) rate deploys with a null oracle, and a senior/junior price read
    ///         returns without reverting, so administrator pricing with no oracle still works.
    function test_initialize_succeedsForAdminRateWithNullOracle_andPriceReadWorks() public {
        bytes memory initData = _encodeInitCall(ADMIN_RATE_WAD, address(0), STALENESS_48H);
        DayKernel proxy = DayKernel(address(new ERC1967Proxy(KERNEL_IMPL, initData))); // must not revert

        assertEq(proxy.getStoredConversionRateWAD(), ADMIN_RATE_WAD, "administrator rate not stored");
        // The read prices the base asset against NAV from the stored administrator rate and never queries the oracle.
        assertGt(proxy.getTrancheUnitToNAVUnitConversionRateWAD(), 0, "administrator-priced read must return a positive rate");
    }

    /// @notice A sentinel stored rate with a non-null oracle and a positive threshold deploys successfully.
    function test_initialize_succeedsForSentinelRateWithValidOracle() public {
        bytes memory initData = _encodeInitCall(0, NUSD_REDSTONE_ORACLE, STALENESS_48H);
        DayKernel proxy = DayKernel(address(new ERC1967Proxy(KERNEL_IMPL, initData))); // must not revert

        assertEq(proxy.getStoredConversionRateWAD(), 0, "sentinel stored rate not retained");
        IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState memory config = proxy.getChainlinkOracleConfiguration();
        assertEq(config.oracle, NUSD_REDSTONE_ORACLE, "oracle not stored");
        assertEq(config.stalenessThresholdSeconds, STALENESS_48H, "staleness threshold not stored");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // Helpers
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @dev Encodes an `initialize` call: the standard params reuse the deployed market's values and the LT quoter leg
    ///      reuses the deployed BPT oracle, so only the varied ST/JT Chainlink quoter parameters change per test.
    function _encodeInitCall(uint256 _initialConversionRateWAD, address _oracle, uint48 _stalenessThresholdSeconds) internal view returns (bytes memory) {
        IRoycoDayKernel.RoycoDayKernelState memory kernelState = KERNEL.getState();
        IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams = IRoycoDayKernel.RoycoDayKernelInitParams({
            initialAuthority: address(ACCESS_MANAGER),
            protocolFeeRecipient: kernelState.protocolFeeRecipient,
            stSelfLiquidationBonusWAD: kernelState.stSelfLiquidationBonusWAD,
            roycoBlacklist: kernelState.roycoBlacklist
        });
        DayKernel.KernelSpecificInitParams memory specificParams = DayKernel.KernelSpecificInitParams({
            stAndJTQuoterParams: STJTChainlinkQuoter.ST_JT_QuoterSpecificParams({
                initialConversionRateWAD: _initialConversionRateWAD,
                baseAssetToNavAssetOracle: _oracle,
                stalenessThresholdSeconds: _stalenessThresholdSeconds,
                sequencerUptimeFeed: address(0),
                gracePeriodSeconds: 0
            }),
            ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({ bptOracle: BPT_ORACLE, maxReinvestmentSlippageWAD: LT_SLIPPAGE_WAD })
        });
        return abi.encodeCall(DayKernel.initialize, (standardParams, specificParams));
    }
}
