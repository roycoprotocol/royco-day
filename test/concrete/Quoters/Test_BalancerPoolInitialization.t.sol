// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20MultiTokenErrors } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IERC20MultiTokenErrors.sol";
import { IVaultErrors } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { MockBalancerVault } from "../../mocks/MockBalancerVault.sol";

/**
 * @title Test_BalancerPoolInitialization_Kernel
 * @notice The venue add's pool-initialization branch, driven only through the production multi-asset deposit entrypoint:
 *         the first deposit on an uninitialized pool seeds it through the Vault's initialize (net of the dead minimum
 *         BPT, no unbalanced-add haircut), the minimum-out bound is pinned from both sides of the exact boundary, the
 *         preview simulates the seed without latching initialization, and later deposits route through addLiquidity
 * @dev The pool is registered at market deployment but carries no genesis liquidity, so every fixture here starts with
 *      an uninitialized pool and the kernel's add callback must take the initialize branch on first contact
 */
contract Test_BalancerPoolInitialization_Kernel is DayMarketTestBase {
    uint256 internal QUOTE_UNIT;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        QUOTE_UNIT = 10 ** uint256(cell.quoteAsset.decimals);
        // Seed the junior buffer only: JT deposits are not liquidity-gated and never touch the pool, so the pool
        // stays uninitialized while senior-minting multi-asset deposits still clear the coverage requirement
        _seedMarket(0, 30_000e18);
    }

    /// @dev The fixture normally plays the pool initializer by pre-seeding the dead minimum, this suite tests the
    ///      production initialize branch so the pool must start with no genesis liquidity at all
    function _initializePoolMinimumSupply() internal override { }

    /// @dev Funds and approves the LT provider's deposit legs through the production allowance path
    function _fundDepositLegs(address _actor, uint256 _stAssets, uint256 _quoteAssets) internal {
        if (_stAssets != 0) stJtVault.mintShares(_actor, _stAssets);
        if (_quoteAssets != 0) quoteToken.mint(_actor, _quoteAssets);
        vm.startPrank(_actor);
        if (_stAssets != 0) stJtVault.approve(address(liquidityTranche), _stAssets);
        if (_quoteAssets != 0) quoteToken.approve(address(liquidityTranche), _quoteAssets);
        vm.stopPrank();
    }

    /**
     * @notice The first quote-only multi-asset deposit initializes the pool: the genesis BPT is the seed's fair value
     *         with the dead minimum burned to the null address, and every ledger lands exactly net of that burn
     * @dev Derivation: 8000 quote units value to 8000e18 WAD at the 1.0 default price, the Vault mints 8000e18 total
     *      supply, burns POOL_MINIMUM_TOTAL_SUPPLY (1e6) dead, and credits the kernel 8000e18 - 1e6. The pool's NAV
     *      per BPT is exactly 1.0 (8000e18 of value backing 8000e18 supply), so the LT bootstrap mints shares 1:1
     *      with the net deposit NAV
     */
    function test_FirstMultiAssetDeposit_QuoteOnly_InitializesPoolNetOfDeadMinimum() public {
        assertFalse(balancerVault.isPoolInitialized(address(bpt)), "precondition: the pool carries no genesis liquidity");
        uint256 quoteAssets = 8000 * QUOTE_UNIT;
        uint256 expectedNet = 8000e18 - balancerVault.POOL_MINIMUM_TOTAL_SUPPLY();
        _fundDepositLegs(LT_PROVIDER, 0, quoteAssets);

        vm.prank(LT_PROVIDER);
        (uint256 shares,) = liquidityTranche.depositMultiAsset(0, quoteAssets, expectedNet, LT_PROVIDER);

        assertTrue(balancerVault.isPoolInitialized(address(bpt)), "the first deposit must latch the pool initialized");
        assertEq(shares, expectedNet, "the LT bootstrap must mint shares 1:1 with the net genesis deposit NAV");
        assertEq(bpt.balanceOf(address(kernel)), expectedNet, "the kernel must custody exactly the net genesis BPT");
        assertEq(bpt.balanceOf(address(0)), balancerVault.POOL_MINIMUM_TOTAL_SUPPLY(), "the dead minimum must be burned to the null address");
        assertEq(bpt.totalSupply(), 8000e18, "the total supply must be the seed's full fair value including the dead minimum");
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), expectedNet, "the kernel's LT ledger must credit the net BPT");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), expectedNet, "the committed LT raw NAV must be the net genesis value");
        uint256[2] memory poolBalances = balancerVault.getPoolBalances(address(bpt));
        assertEq(poolBalances[stPoolTokenIndex], 0, "no senior leg was seeded");
        assertEq(poolBalances[1 - stPoolTokenIndex], quoteAssets, "the quote leg must seed the pool balance exactly");
    }

    /**
     * @notice The genesis seed's minimum-out bound is checked against the NET mint and pinned from BOTH sides of the
     *         exact boundary: one wei above the net reverts with the Vault's floor error and unwinds the initialization
     *         latch, exactly the net succeeds
     * @dev Attacker intent: the dead minimum burn makes the receiver's BPT 1e6 short of the gross fair value, an
     *      off-by-one against the gross here would let a caller-set floor pass while receiving less than it demands
     */
    function test_InitializeSeed_MinLTAssetsOutBoundary_BothSides() public {
        uint256 quoteAssets = 8000 * QUOTE_UNIT;
        uint256 expectedNet = 8000e18 - balancerVault.POOL_MINIMUM_TOTAL_SUPPLY();
        _fundDepositLegs(LT_PROVIDER, 0, quoteAssets);

        // Side 1: one wei above the net mint, the Vault's floor throws and the whole deposit unwinds
        vm.prank(LT_PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.BptAmountOutBelowMin.selector, expectedNet, expectedNet + 1));
        liquidityTranche.depositMultiAsset(0, quoteAssets, expectedNet + 1, LT_PROVIDER);
        assertFalse(balancerVault.isPoolInitialized(address(bpt)), "a reverted seed must unwind the initialization latch");
        assertEq(liquidityTranche.totalSupply(), 0, "a reverted seed must mint no LT shares");

        // Side 2: exactly the net mint passes and seeds the pool
        vm.prank(LT_PROVIDER);
        (uint256 shares,) = liquidityTranche.depositMultiAsset(0, quoteAssets, expectedNet, LT_PROVIDER);
        assertEq(shares, expectedNet, "the floor at exactly the net mint must pass");
        assertTrue(balancerVault.isPoolInitialized(address(bpt)), "the exact-floor seed must latch the pool initialized");
    }

    /**
     * @notice The multi-asset preview on an uninitialized pool simulates the genesis seed: it quotes exactly the
     *         executed shares (net of the dead minimum) while latching NOTHING, and the execution then matches it
     */
    function test_PreviewMultiAssetDeposit_UninitializedPool_MatchesExecutionAndLatchesNothing() public {
        uint256 quoteAssets = 8000 * QUOTE_UNIT;
        _fundDepositLegs(LT_PROVIDER, 0, quoteAssets);

        (uint256 quoted,) = liquidityTranche.previewDepositMultiAsset(0, quoteAssets);
        assertFalse(balancerVault.isPoolInitialized(address(bpt)), "the preview must unwind the simulated seed's initialization latch");
        assertEq(bpt.totalSupply(), 0, "the preview must unwind the simulated genesis mint");

        vm.prank(LT_PROVIDER);
        (uint256 shares,) = liquidityTranche.depositMultiAsset(0, quoteAssets, 0, LT_PROVIDER);
        assertEq(quoted, shares, "the preview must quote exactly the executed genesis seed's shares");
    }

    /**
     * @notice Branch selection pinned by the unbalanced-add haircut: the genesis seed pays no haircut (initialize
     *         charges no swap fee), the very next deposit routes through addLiquidity and pays it
     * @dev Derivation: with a 1% haircut armed, the 8000-quote genesis still credits 8000e18 - 1e6 net (no fee), while
     *      the follow-up 1000-quote add prices at fair value 1000e18 against the 1.0 NAV-per-BPT pool and is haircut
     *      to 990e18 BPT, observable as the kernel's exact BPT delta
     */
    function test_SecondDeposit_RoutesThroughAddLiquidity_HaircutDiscriminatesBranches() public {
        balancerVault.setUnbalancedFeeBps(100);
        uint256 expectedNet = 8000e18 - balancerVault.POOL_MINIMUM_TOTAL_SUPPLY();
        _fundDepositLegs(LT_PROVIDER, 0, 8000 * QUOTE_UNIT);
        vm.prank(LT_PROVIDER);
        liquidityTranche.depositMultiAsset(0, 8000 * QUOTE_UNIT, expectedNet, LT_PROVIDER);
        assertEq(bpt.balanceOf(address(kernel)), expectedNet, "the genesis seed must pay no unbalanced-add haircut");

        _fundDepositLegs(LT_PROVIDER, 0, 1000 * QUOTE_UNIT);
        uint256 kernelBptBefore = bpt.balanceOf(address(kernel));
        vm.prank(LT_PROVIDER);
        liquidityTranche.depositMultiAsset(0, 1000 * QUOTE_UNIT, 0, LT_PROVIDER);
        assertEq(bpt.balanceOf(address(kernel)) - kernelBptBefore, 990e18, "the follow-up add must route through addLiquidity and pay the haircut");
    }

}

/**
 * @title Test_BalancerPoolInitialization_SeniorLeg_Kernel
 * @notice The initialize branch's senior leg: a zero minimum-liquidity market seeds its senior side first (the empty
 *         pool cannot gate ST deposits), so the committed senior share rate is exactly 1.0 when the first multi-asset
 *         deposit mints and deploys senior exposure into the genesis seed
 */
contract Test_BalancerPoolInitialization_SeniorLeg_Kernel is DayMarketTestBase {
    uint256 internal QUOTE_UNIT;

    function setUp() public {
        MarketParamsConfig memory p = defaultParams();
        // ST deposits are liquidity-gated against an empty pool, zeroing the requirement lets the senior side seed
        // first so the senior leg prices at the committed 1.0 rate instead of a degenerate empty-market rate
        p.minLiquidityWAD = 0;
        _deployMarket(cellA(), p);
        QUOTE_UNIT = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(1000e18, 500e18);
    }

    /// @dev The fixture normally plays the pool initializer by pre-seeding the dead minimum, this suite tests the
    ///      production initialize branch so the pool must start with no genesis liquidity at all
    function _initializePoolMinimumSupply() internal override { }

    /// @dev Funds and approves the LT provider's deposit legs through the production allowance path
    function _fundDepositLegs(address _actor, uint256 _stAssets, uint256 _quoteAssets) internal {
        if (_stAssets != 0) stJtVault.mintShares(_actor, _stAssets);
        if (_quoteAssets != 0) quoteToken.mint(_actor, _quoteAssets);
        vm.startPrank(_actor);
        if (_stAssets != 0) stJtVault.approve(address(liquidityTranche), _stAssets);
        if (_quoteAssets != 0) quoteToken.approve(address(liquidityTranche), _quoteAssets);
        vm.stopPrank();
    }

    /**
     * @notice A both-legs first deposit initializes the pool with the senior leg minted and deployed in the same flow
     * @dev Derivation with the virtual-shares/assets offset. The ST leg mints _convertToShares(100e18, 1000e18, 1000e18)
     *      = floor((1000e18 + 1e6) x 100e18 / (1000e18 + 1)) = 100000000000000099999 senior shares (slightly over the
     *      naive 100e18 as the offset lifts the numerator supply). The pool prices that leg at the pre-op cached senior
     *      rate _convertToValue(WAD, 1000e18, 1000e18) = 999999999999999000, so the senior leg values to
     *      floor(100000000000000099999 x 999999999999999000 / 1e18) = 99999999999999999998 WAD; the 100 quote units value
     *      to 100e18 WAD, so the genesis mint is 199999999999999999998 gross and 199999999999998999998 net of the 1e6
     *      dead minimum. NAV-per-BPT is exactly 1.0 (gross value == gross supply), so the fresh LT bootstrap mints the net
     *      1:1
     */
    function test_FirstMultiAssetDeposit_BothLegs_InitializesPool() public {
        uint256 stAssets = 100e18;
        uint256 quoteAssets = 100 * QUOTE_UNIT;
        // Offset-derived net genesis NAV (see docstring): 199999999999999999998 gross less the 1e6 dead minimum
        uint256 expectedNet = 199999999999998999998;
        _fundDepositLegs(LT_PROVIDER, stAssets, quoteAssets);

        vm.prank(LT_PROVIDER);
        (uint256 shares,) = liquidityTranche.depositMultiAsset(stAssets, quoteAssets, expectedNet, LT_PROVIDER);

        assertTrue(balancerVault.isPoolInitialized(address(bpt)), "the first deposit must latch the pool initialized");
        assertEq(shares, expectedNet, "the LT bootstrap must mint shares 1:1 with the net genesis deposit NAV");
        assertEq(seniorTranche.totalSupply(), 1100000000000000099999, "the senior leg must mint exactly the offset-priced deposited vault shares (1000e18 seed + 100000000000000099999)");
        uint256[2] memory poolBalances = balancerVault.getPoolBalances(address(bpt));
        assertEq(poolBalances[stPoolTokenIndex], 100000000000000099999, "the minted senior shares must seed the pool's senior balance");
        assertEq(poolBalances[1 - stPoolTokenIndex], quoteAssets, "the quote leg must seed the pool balance exactly");
    }

    /**
     * @notice A genesis seed too small to cover the dead minimum reverts with the Vault's total-supply floor, the
     *         real vault's guard against dust-value initialization
     * @dev Derivation with the offset: 1000 wei of vault shares mint _convertToShares(1000, 1000e18, 1000e18) = 1000 wei
     *      of senior shares (the offset leaves this dust mint unchanged), valued at the pre-op cached senior rate
     *      999999999999999000, so the genesis gross BPT is floor(1000 x 999999999999999000 / 1e18) = 999 WAD wei, under
     *      the 1e6 dead minimum, so the Vault refuses to initialize with the gross figure and the whole deposit unwinds
     */
    function test_RevertIf_GenesisSeedBelowDeadMinimum() public {
        uint256 stAssets = 1000;
        _fundDepositLegs(LT_PROVIDER, stAssets, 0);

        vm.prank(LT_PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IERC20MultiTokenErrors.PoolTotalSupplyTooLow.selector, 999));
        liquidityTranche.depositMultiAsset(stAssets, 0, 0, LT_PROVIDER);
        assertFalse(balancerVault.isPoolInitialized(address(bpt)), "a dust seed must leave the pool uninitialized");
        assertEq(seniorTranche.totalSupply(), 1000e18, "the reverted seed must unwind its senior leg mint");
    }

    /**
     * @notice Premium reinvestment on an uninitialized pool defers cleanly: the empty pool's zero BPT supply floors
     *         the reinvest gate's fair-value conversion to zero, the attempt preemptively returns, the premium stays
     *         idle, and no sync or explicit reinvest can brick or seed the pool. The first genesis deposit then
     *         unblocks the deferred pile end to end
     * @dev Pins that ltConvertNAVUnitsToTrancheUnits returns zero at zero BPT supply, so the gate's zero-floor
     *      early return (not the tolerated-failure path) is what defers: no LiquidityPremiumReinvestmentFailed
     *      state change, no unprotected add, and the pool must never be initialized by a reinvestment
     */
    function test_ReinvestOnUninitializedPool_DefersWithIdlePremiumIntact() public {
        // Accrue senior yield across a day so the sync mints the liquidity premium as idle senior shares, the
        // sync's own auto-reinvest attempt must defer against the uninitialized pool instead of reverting
        applySTPnL(200);
        vm.warp(block.timestamp + 1 days);
        _sync();
        uint256 idleShares = kernel.getState().ltOwnedSeniorTrancheShares;
        assertGt(idleShares, 0, "the sync must stage the premium as idle senior shares");
        assertFalse(balancerVault.isPoolInitialized(address(bpt)), "the sync's auto-reinvest must never seed the pool");
        assertEq(toUint256(kernel.getState().ltOwnedYieldBearingAssets), 0, "no BPT may be credited by a deferred reinvest");

        // An explicit reinvest against the uninitialized pool defers identically, the idle pile is untouched
        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN);
        kernel.reinvestLiquidityPremium(type(uint256).max);
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, idleShares, "the explicit reinvest must leave the idle pile untouched");
        assertFalse(balancerVault.isPoolInitialized(address(bpt)), "the explicit reinvest must never seed the pool");

        // A genesis deposit seeds the pool, the deferred pile then deploys in full through the same reinvest
        _fundDepositLegs(LT_PROVIDER, 0, 1000 * QUOTE_UNIT);
        vm.prank(LT_PROVIDER);
        liquidityTranche.depositMultiAsset(0, 1000 * QUOTE_UNIT, 0, LT_PROVIDER);
        uint256 kernelBptBefore = bpt.balanceOf(address(kernel));
        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN);
        kernel.reinvestLiquidityPremium(type(uint256).max);
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, 0, "the seeded pool must unblock the entire deferred pile");
        assertGt(bpt.balanceOf(address(kernel)) - kernelBptBefore, 0, "the unblocked reinvest must credit the kernel new BPT");
    }

    /**
     * @notice A forced venue failure during the genesis seed is fully atomic: the senior leg mint, every kernel
     *         ledger, and the initialization latch all unwind, and the same deposit succeeds once the venue recovers
     */
    function test_RevertIf_GenesisSeedVenueForcedRevert_FullyAtomic() public {
        uint256 stAssets = 100e18;
        uint256 quoteAssets = 100 * QUOTE_UNIT;
        _fundDepositLegs(LT_PROVIDER, stAssets, quoteAssets);
        balancerVault.setRevertMode(MockBalancerVault.RevertMode.ADD);

        vm.prank(LT_PROVIDER);
        vm.expectRevert(MockBalancerVault.FORCED_ADD_REVERT.selector);
        liquidityTranche.depositMultiAsset(stAssets, quoteAssets, 0, LT_PROVIDER);

        assertFalse(balancerVault.isPoolInitialized(address(bpt)), "the failed seed must unwind the initialization latch");
        assertEq(seniorTranche.totalSupply(), 1000e18, "the failed seed must unwind its senior leg mint");
        assertEq(liquidityTranche.totalSupply(), 0, "the failed seed must mint no LT shares");
        assertEq(bpt.balanceOf(address(kernel)), 0, "the failed seed must credit no BPT");
        assertEq(stJtVault.balanceOf(LT_PROVIDER), stAssets, "the failed seed must refund the senior leg");
        assertEq(quoteToken.balanceOf(LT_PROVIDER), quoteAssets, "the failed seed must refund the quote leg");

        // The venue recovers and the identical deposit seeds the genesis
        balancerVault.setRevertMode(MockBalancerVault.RevertMode.NONE);
        vm.prank(LT_PROVIDER);
        liquidityTranche.depositMultiAsset(stAssets, quoteAssets, 0, LT_PROVIDER);
        assertTrue(balancerVault.isPoolInitialized(address(bpt)), "the recovered venue must seed the genesis");
    }
}
