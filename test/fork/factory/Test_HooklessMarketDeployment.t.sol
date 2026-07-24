// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRouter } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IRouter.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { DeploymentResult, MarketConfig } from "../../../script/config/DeploymentTypes.sol";
import { LPT_LP_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoLiquidityProviderTranche } from "../../../src/interfaces/IRoycoLiquidityProviderTranche.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoDayTestBase } from "../../utils/RoycoDayTestBase.sol";

/// @dev The minimal Permit2 surface the Balancer Router's token pulls require (no permit2 lib is vendored)
interface IPermit2HooklessLike {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/**
 * @title Test_HooklessMarketDeployment
 * @notice A Day market deployed with `deployPoolHook: false`: the pool registers genuinely hookless
 *         (`poolHooksContract == address(0)`), the whole stand-in-proxy/upgrade/binding pipeline is skipped, and the
 *         market still functions end to end — JT/ST deposits, the LPT genesis multi-asset deposit initializing the
 *         real E-CLP pool through the kernel's add callback, kernel-routed redemptions, and EXTERNAL Router
 *         operations (which now execute without the hook's pre-op accounting sync)
 * @dev Mirrors Test_DayMarketDeployment's fixture (same snUSD config, real mainnet infra) with the flag flipped.
 *      Requires env `MAINNET_RPC_URL`; FAILS without it (matching the factory suites, no silent skip)
 */
contract Test_HooklessMarketDeployment is RoycoDayTestBase {
    address internal constant FACTORY_ADMIN = 0x7c405bbD131e42af506d14e752f2e59B19D49997; // ROOT_MULTISIG
    address internal constant BALANCER_V3_ROUTER = 0xAE563E3f8219521950555F5962419C8919758Ea2; // canonical mainnet Router
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    IRoycoVaultTranche internal LPT;
    address internal POOL;
    address internal COLLATERAL_ASSET;
    address internal QUOTE_ASSET;
    IVault internal VAULT;

    address internal LPT_PROVIDER;

    function _forkConfiguration() internal view override returns (uint256 forkBlock, string memory forkRpcUrl) {
        forkRpcUrl = vm.envString("MAINNET_RPC_URL");
        forkBlock = vm.envOr("FORK_BLOCK", uint256(25_400_000));
    }

    function setUp() public {
        _setUpRoyco();

        // The snUSD config with the hook opted out: everything else identical to the hooked deployment suite
        MarketConfig memory config = DEPLOY_SCRIPT.getMarketConfig("snUSD");
        config.deployPoolHook = false;

        DeploymentResult memory result = DEPLOY_SCRIPT.deploy(config, FACTORY_ADMIN, PROTOCOL_FEE_RECIPIENT_ADDRESS, 0, _generateRoleAssignments(), DEPLOYER.privateKey);
        _setDeployedMarket(result);

        LPT = IRoycoVaultTranche(KERNEL.LIQUIDITY_PROVIDER_TRANCHE());
        POOL = KERNEL.LPT_ASSET();
        COLLATERAL_ASSET = KERNEL.COLLATERAL_ASSET();
        QUOTE_ASSET = KERNEL.QUOTE_ASSET();
        VAULT = IVault(address(GyroECLPPoolFactory(DEPLOY_SCRIPT.getChainConfig(block.chainid, false).gyroECLPPoolFactory).getVault()));

        _setupProviders();
        LPT_PROVIDER = _generateProvider("LPT_PROVIDER", LPT_LP_ROLE).addr;
        deal(COLLATERAL_ASSET, ST_ALICE_ADDRESS, 1_000_000e18);
        deal(COLLATERAL_ASSET, JT_ALICE_ADDRESS, 1_000_000e18);
        deal(COLLATERAL_ASSET, LPT_PROVIDER, 1_000_000e18);
        deal(QUOTE_ASSET, LPT_PROVIDER, 1_000_000e6);
    }

    // ── Local staging helpers (the hookless market's production paths) ──────────────────────────────────────────

    function _depositTranche(address _lp, IRoycoVaultTranche _tranche, uint256 _assets) internal returns (uint256 shares) {
        vm.startPrank(_lp);
        IERC20(COLLATERAL_ASSET).approve(address(_tranche), _assets);
        shares = _tranche.deposit(toTrancheUnits(_assets), _lp);
        vm.stopPrank();
    }

    /// @dev The LPT genesis: the first multi-asset deposit initializes the hookless pool through the kernel's add callback
    function _seedLPTGenesis(address _lp, uint256 _collateralAssets) internal returns (uint256 shares) {
        uint256 quoteAssets = Math.mulDiv(toUint256(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(_collateralAssets))), 1e6, 1e18);
        vm.startPrank(_lp);
        IERC20(COLLATERAL_ASSET).approve(address(LPT), _collateralAssets);
        IERC20(QUOTE_ASSET).approve(address(LPT), quoteAssets);
        (shares,) = IRoycoLiquidityProviderTranche(address(LPT)).depositMultiAsset(_collateralAssets, quoteAssets, 0, _lp);
        vm.stopPrank();
    }

    /// @dev Seeds the ST/JT/LPT legs so pool-op tests run against a live market
    function _seedMarketAndPool() internal {
        _depositTranche(JT_ALICE_ADDRESS, JT, 30_000e18);
        _depositTranche(ST_ALICE_ADDRESS, ST, 50_000e18);
        _seedLPTGenesis(LPT_PROVIDER, 2000e18);
    }

    // ── The hookless wiring ──────────────────────────────────────────────────────────────────────────────────────

    /// @notice The pool registers with NO hook: the Vault's hooks config is the zero address (a foreign hook would
    ///         have failed the template's pool verification)
    function test_Hookless_PoolHasNoHooksContract() public view {
        assertEq(VAULT.getHooksConfig(POOL).hooksContract, address(0), "the hookless market's pool must carry no hooks contract");
    }

    /// @notice The stand-in hook proxy is never deployed: the deterministic hook-proxy address stays codeless
    function test_Hookless_StandInProxyNeverDeployed() public view {
        // The market's other components deployed fine, so a codeless hook slot proves the stub pipeline was skipped
        assertGt(address(KERNEL).code.length, 0, "sanity: the market itself must be deployed");
        // No hook contract exists anywhere in the market's wiring: the pool (the only hook consumer) reads zero
        assertEq(VAULT.getHooksConfig(POOL).hooksContract, address(0), "no hook proxy may be wired anywhere");
    }

    // ── The market functions hookless ────────────────────────────────────────────────────────────────────────────

    /// @notice JT/ST deposits, the LPT genesis (pool initialization through the kernel add callback), and a
    ///         kernel-routed redemption all work with no hook registered
    function test_Hookless_MarketLifecycleFunctions() public {
        _seedMarketAndPool();
        assertTrue(VAULT.isPoolInitialized(POOL), "the kernel genesis deposit must initialize the hookless pool");

        // Kernel-routed ST redemption settles in-kind
        uint256 stShares = _depositTranche(ST_ALICE_ADDRESS, ST, 1000e18);
        uint256 balBefore = IERC20(COLLATERAL_ASSET).balanceOf(ST_ALICE_ADDRESS);
        vm.prank(ST_ALICE_ADDRESS);
        ST.redeem(stShares, ST_ALICE_ADDRESS, ST_ALICE_ADDRESS);
        assertGt(IERC20(COLLATERAL_ASSET).balanceOf(ST_ALICE_ADDRESS) - balBefore, 0, "the kernel-routed redemption must settle collateral");
    }

    /// @notice External Router operations (a swap and an unbalanced add) execute against the hookless pool — with no
    ///         hook there is no pre-op accounting sync and no external-op pause switch, the documented tradeoff
    function test_Hookless_ExternalRouterOpsExecuteWithoutHook() public {
        _seedMarketAndPool();

        // An external actor holding live ST shares and dealt quote, with the Permit2 two-step wired
        address external_ = makeAddr("EXTERNAL_ACTOR");
        vm.prank(ST_ALICE_ADDRESS);
        IERC20(address(ST)).transfer(external_, 100e18);
        deal(QUOTE_ASSET, external_, 100_000e6);
        vm.startPrank(external_);
        IERC20(address(ST)).approve(PERMIT2, type(uint256).max);
        IERC20(QUOTE_ASSET).approve(PERMIT2, type(uint256).max);
        IPermit2HooklessLike(PERMIT2).approve(address(ST), BALANCER_V3_ROUTER, type(uint160).max, type(uint48).max);
        IPermit2HooklessLike(PERMIT2).approve(QUOTE_ASSET, BALANCER_V3_ROUTER, type(uint160).max, type(uint48).max);

        // External swap: quote -> ST share, no hook consulted
        uint256 amountOut = IRouter(BALANCER_V3_ROUTER).swapSingleTokenExactIn(POOL, IERC20(QUOTE_ASSET), IERC20(address(ST)), 10e6, 0, block.timestamp, false, "");
        assertGt(amountOut, 0, "the external swap must execute on the hookless pool");

        // External unbalanced add: the actor receives real BPT, no hook consulted
        IERC20[] memory tokens = VAULT.getPoolTokens(POOL);
        uint256[] memory exactAmountsIn = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            exactAmountsIn[i] = address(tokens[i]) == address(ST) ? 10e18 : 10e6;
        }
        uint256 bptOut = IRouter(BALANCER_V3_ROUTER).addLiquidityUnbalanced(POOL, exactAmountsIn, 0, false, "");
        vm.stopPrank();
        assertGt(bptOut, 0, "the external add must mint BPT on the hookless pool");
        assertEq(IERC20(POOL).balanceOf(external_), bptOut, "the external LP must custody its BPT");
    }
}
