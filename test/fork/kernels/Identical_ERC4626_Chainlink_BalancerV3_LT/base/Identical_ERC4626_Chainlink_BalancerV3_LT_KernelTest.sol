// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRouter } from "../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IRouter.sol";
import { IERC20 } from "../../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AggregatorV3Interface } from "../../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import {
    IdenticalAssets_ST_JT_ChainlinkOracle_Quoter
} from "../../../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol";
import { Test_KernelSuiteBase } from "../../Test_KernelSuiteBase.t.sol";
import { IRoycoLiquidityTranche } from "../../../../../src/interfaces/IRoycoLiquidityTranche.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../../../src/libraries/Units.sol";

/// @dev The minimal Permit2 surface the Balancer Router's token pulls require (no permit2 lib is vendored).
interface IPermit2Like {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/**
 * @title Identical_ERC4626_Chainlink_BalancerV3_LT_KernelTest
 * @notice Per-kernel-type test base for the `Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel`
 *         family: ST and JT are the same ERC4626 vault share (priced share->base via the vault and base->NAV via a
 *         Chainlink-compatible feed), and the LT holds the Gyro E-CLP BPT of `{ST_share, quote}`.
 * @dev Implements the `IKernelTestHooks` deal + simulate seams once for this kernel family, so concrete protocol tests
 *      supply only `getTestConfig`, `_deployKernelAndMarket` (the market name), the `_baseAssetToNavOracle` address, and
 *      the rounding tolerances. No `test_*` methods yet.
 */
abstract contract Identical_ERC4626_Chainlink_BalancerV3_LT_KernelTest is Test_KernelSuiteBase {
    /// @dev Cached base->NAV feed answer, mocked once then moved by `simulate*`; re-stamped fresh after warps.
    int256 internal _mockedOracleAnswer;
    bool internal _oracleMocked;

    /// @dev The base(asset)->NAV Chainlink-compatible feed backing this market (e.g. the RedStone nUSD feed for snUSD).
    function _baseAssetToNavOracle() internal view virtual returns (address);

    // ═══════════════════════════════════════════════════════════════════════════
    // DEAL HOOKS — real tokens, funded via forge `deal`
    // ═══════════════════════════════════════════════════════════════════════════

    function dealSTAsset(address _to, uint256 _amount) public virtual override {
        deal(testConfig.stAsset, _to, _amount);
    }

    function dealJTAsset(address _to, uint256 _amount) public virtual override {
        deal(testConfig.jtAsset, _to, _amount);
    }

    function dealQuoteAsset(address _to, uint256 _amount) public virtual override {
        if (testConfig.quoteAsset != address(0)) deal(testConfig.quoteAsset, _to, _amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SIMULATE HOOKS — move the base->NAV leg by mocking the Chainlink-compatible feed
    // ═══════════════════════════════════════════════════════════════════════════
    // NOTE: ST and JT share the same asset + the same base->NAV feed, so a feed move affects BOTH legs by the same
    //      fraction. Isolating a single tranche's NAV is not possible via this axis. A share-price axis (`vm.mockCall`
    //      on the vault's `convertToAssets`) can be layered in when yield tests need it.

    function simulateSTYield(uint256 _percentageWAD) public virtual override {
        _moveOracle(int256(1), _percentageWAD);
    }

    function simulateJTYield(uint256 _percentageWAD) public virtual override {
        _moveOracle(int256(1), _percentageWAD);
    }

    function simulateSTLoss(uint256 _percentageWAD) public virtual override {
        _moveOracle(int256(-1), _percentageWAD);
    }

    function simulateJTLoss(uint256 _percentageWAD) public virtual override {
        _moveOracle(int256(-1), _percentageWAD);
    }

    /// @dev Yield realization is immediate here (no rebasing/streaming), so no time warp is required.
    function _requiresTimeWarpForYield() internal virtual override returns (bool) {
        return false;
    }

    /// @dev The Chainlink quoter family's staleness selector, enabling the abstract suite's staleness brick test.
    function _oracleStalenessSelector() internal pure virtual override returns (bytes4) {
        return IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.STALE_PRICE.selector;
    }

    /**
     * @dev Keep the mocked feed's `updatedAt` fresh at the current (post-warp) time so the kernel's staleness check keeps
     *      passing. Self-seeding: when no simulate has run yet, the mock is seeded from the real feed's live answer (a 0%
     *      move) and stamped fresh, so admin-op warps never leave the market quoting a stale feed.
     */
    function _refreshOraclesAfterWarp() internal virtual override {
        if (!_oracleMocked) _pinOracleFresh();
        else _applyOracleMock(_baseAssetToNavOracle());
    }

    /// @dev Freeze the base->NAV feed's live value into the mock (a 0% move) while it is still fresh, so a later warp can
    ///      re-stamp it via `_refreshOraclesAfterWarp` without re-reading a by-then-stale real feed.
    function _pinOracleFresh() internal {
        _moveOracle(int256(1), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VENUE BOOTSTRAP — one-time Balancer pool initialization via the canonical Router
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Balancer's canonical V3 Router (the 20250307-v3-router-v2 mainnet deployment). Other chains override.
    function _balancerV3Router() internal view virtual returns (address) {
        return 0xAE563E3f8219521950555F5962419C8919758Ea2;
    }

    /// @dev The canonical Permit2 the Balancer Router pulls tokens through (same address on every chain).
    function _canonicalPermit2() internal view virtual returns (address) {
        return 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    }

    /**
     * @dev Initializes the market's freshly created Gyro E-CLP pool through Balancer's canonical Router when it
     *      is still uninitialized, since Balancer rejects the kernel's UNBALANCED adds (`PoolNotInitialized`)
     *      until the pool is initialized.
     * @dev Production now initializes the pool itself: the kernel's add callback routes the first add through
     *      `Vault.initialize` when the pool is uninitialized, so a fresh Day market's LT surface is usable from
     *      the first multi-asset deposit (pinned by the production-genesis fork tests below). This helper remains
     *      as the historical ops-style bootstrap through the venue's own Router for suites that want a dust-deep
     *      two-sided pool BEFORE the first kernel add, funding the dust senior leg with live ST shares borrowed
     *      from ST_ALICE so no new senior exposure is created and no coverage/liquidity gate is consulted.
     */
    function _initializeLTVenueIfNeeded() internal virtual override {
        if (!testConfig.hasLiquidityTranche || VAULT.isPoolInitialized(POOL)) return;

        // Dust seed: ~1 unit of value per side, sized in each token's own decimals
        uint256 initSTShares = 1e18;
        uint256 initQuoteAssets = 10 ** IERC20Metadata(testConfig.quoteAsset).decimals();

        // Arrange-guard: the bootstrap borrows live ST shares, so the ST/JT market must be seeded first
        assertGt(ST.balanceOf(ST_ALICE_ADDRESS), initSTShares, "venue init: seed the ST/JT market before seeding the LT");

        address initializer = makeAddr("BALANCER_POOL_INITIALIZER");
        vm.prank(ST_ALICE_ADDRESS);
        IERC20(address(ST)).transfer(initializer, initSTShares);
        dealQuoteAsset(initializer, initQuoteAssets);

        // The Router pulls both legs through Permit2, so wire the two-step allowances
        address router = _balancerV3Router();
        address permit2 = _canonicalPermit2();
        vm.startPrank(initializer);
        IERC20(address(ST)).approve(permit2, type(uint256).max);
        IERC20(testConfig.quoteAsset).approve(permit2, type(uint256).max);
        IPermit2Like(permit2).approve(address(ST), router, type(uint160).max, type(uint48).max);
        IPermit2Like(permit2).approve(testConfig.quoteAsset, router, type(uint160).max, type(uint48).max);

        // Initialize with the pool's registered token order. The dust BPT stays with the initializer
        IERC20[] memory tokens = VAULT.getPoolTokens(POOL);
        uint256[] memory exactAmountsIn = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            exactAmountsIn[i] = address(tokens[i]) == address(ST) ? initSTShares : initQuoteAssets;
        }
        IRouter(router).initialize(POOL, tokens, exactAmountsIn, 0, false, "");
        vm.stopPrank();
    }

    function _moveOracle(int256 _sign, uint256 _percentageWAD) internal {
        address oracle = _baseAssetToNavOracle();
        if (!_oracleMocked) {
            (, int256 answer,,,) = AggregatorV3Interface(oracle).latestRoundData();
            _mockedOracleAnswer = answer;
            _oracleMocked = true;
        }
        _mockedOracleAnswer += _sign * ((_mockedOracleAnswer * int256(_percentageWAD)) / int256(1e18));
        _applyOracleMock(oracle);
    }

    function _applyOracleMock(address _oracle) internal {
        vm.mockCall(
            _oracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), _mockedOracleAnswer, block.timestamp, block.timestamp, uint80(1))
        );
    }

    /**
     * @notice The production genesis on the real Vault: the first multi-asset deposit on the freshly deployed,
     *         uninitialized E-CLP pool initializes it through the kernel's add callback, no out-of-band Router
     *         bootstrap involved, with the real minimum-supply burn and full kernel custody of the live BPT
     * @dev Also pins the primitive that makes premium reinvestment defer against an uninitialized pool: the
     *      NAV-to-BPT conversion floors to zero at zero BPT supply, so the reinvest gate preemptively returns
     *      before ever reaching the Vault
     */
    function test_LTMultiAssetDeposit_FirstDepositInitializesPool_ProductionGenesis() public {
        if (!testConfig.hasLiquidityTranche) return;
        _setupLTProviders();
        _seedMarket(testConfig.initialFunding / 100, testConfig.initialFunding / 100);
        assertFalse(VAULT.isPoolInitialized(POOL), "precondition: the deploy script must leave the pool uninitialized");
        assertEq(
            toUint256(KERNEL.ltConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(1e18)))),
            0,
            "the zero-supply conversion floor must hold on the real vault, the reinvest defer primitive"
        );

        // An in-band genesis: value-matched legs, the same shape the ops bootstrap seeds
        uint256 stAssets = 1e18;
        uint256 quoteAssets = _quoteAssetsForValue(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(stAssets)));
        OpReceipt memory r = _doDepositLTMulti(LT_ALICE_ADDRESS, stAssets, quoteAssets, 0);

        assertTrue(VAULT.isPoolInitialized(POOL), "the first production deposit must initialize the pool");
        uint256 dead = IERC20(POOL).balanceOf(address(0));
        assertEq(dead, 1e6, "the real vault must burn the minimum supply to the null address");
        assertEq(IERC20(POOL).balanceOf(address(KERNEL)), IERC20(POOL).totalSupply() - dead, "the kernel must custody every live genesis BPT");
        assertEq(
            toUint256(KERNEL.getState().ltOwnedYieldBearingAssets),
            IERC20(POOL).balanceOf(address(KERNEL)),
            "the kernel's LT ledger must credit exactly its custodied genesis BPT"
        );
        assertEq(r.shares, LT.totalSupply(), "the genesis LP must hold the entire LT supply");
    }

    /**
     * @notice The multi-asset preview on the uninitialized real pool simulates the genesis through the Vault's
     *         real invariant math and unwinds it: the quote equals the executed shares to the wei while latching
     *         nothing, and a minimum-out at exactly the quote passes where one wei above must fail
     */
    function test_LTMultiAssetDeposit_UninitializedPoolPreview_MatchesExecutionAndLatchesNothing() public {
        if (!testConfig.hasLiquidityTranche) return;
        _setupLTProviders();
        _seedMarket(testConfig.initialFunding / 100, testConfig.initialFunding / 100);
        assertFalse(VAULT.isPoolInitialized(POOL), "precondition: the deploy script must leave the pool uninitialized");

        uint256 stAssets = 1e18;
        uint256 quoteAssets = _quoteAssetsForValue(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(stAssets)));

        // The execute-and-revert preview runs the real initialize inside the unlocked Vault and unwinds it whole
        uint256 quoted = IRoycoLiquidityTranche(address(LT)).previewDepositMultiAsset(stAssets, quoteAssets);
        assertFalse(VAULT.isPoolInitialized(POOL), "the preview must unwind the simulated genesis initialization");
        assertEq(IERC20(POOL).totalSupply(), 0, "the preview must unwind the simulated genesis mint");

        // The executed genesis matches the quote to the wei, pinned as the deposit's own minimum-out floor
        OpReceipt memory r = _doDepositLTMulti(LT_ALICE_ADDRESS, stAssets, quoteAssets, quoted);
        assertEq(r.shares, quoted, "the preview must quote exactly the executed genesis seed's shares");
    }
}
