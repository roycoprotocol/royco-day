// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoAuth } from "../../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../../src/interfaces/IRoycoDayKernel.sol";
import { AssetClaims, MarketState, SyncedAccountingState, TrancheType } from "../../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import {
    Identical_ERC4626_Chainlink_BalancerV3_LPT_KernelTest
} from "../../kernels/Identical_ERC4626_Chainlink_BalancerV3_LPT/base/Identical_ERC4626_Chainlink_BalancerV3_LPT_KernelTest.sol";

/**
 * @title Test_SeniorTrancheDepositWithdrawBase
 * @notice Abstract deposit/withdraw test suite for the SENIOR tranche, run against a real forked market. A concrete
 *         per-market test instantiates it by inheriting both this suite and a market fixture (e.g. `Neutrl_snUSD_Market`);
 *         both share `Test_KernelSuiteBase` as the deploy/setUp base.
 * @dev Covers three concerns: (A) deposits mint the correct shares, (B) deposit/withdraw limits from the
 *      coverage + liquidity utilization gates, and (C) the preview/max surface (previews simulate the real
 *      deposit/redeem path and are not view). Senior mechanics pinned:
 *      - ST deposit: PERPETUAL-only; post-op coverage gate (`COVERAGE_REQUIREMENT_VIOLATED`) AND liquidity gate
 *        (`LIQUIDITY_REQUIREMENT_VIOLATED`); `maxSTDeposit = min(coverage-branch, liquidity-branch)`.
 *      - ST redeem: PERPETUAL-only; NO coverage/liquidity gate; senior tranche self-liquidation bonus once
 *        `coverageUtilizationWAD` reaches the liquidation threshold.
 *      A senior deposit needs a junior coverage buffer to exist first, so tests seed JT before depositing ST.
 *
 *      Shared-asset caveat: ST and JT share one asset and the snUSD market prices both with one base->NAV feed, so the
 *      `simulate*` hooks move both legs together. FIXED_TERM / self-liquidation-bonus tests are therefore best-effort:
 *      they attempt to reach the target state and `vm.skip` (with a reason) if a symmetric-PnL market cannot get there.
 */
abstract contract Test_SeniorTrancheDepositWithdrawBase is Identical_ERC4626_Chainlink_BalancerV3_LPT_KernelTest {
    uint256 internal constant WAD = 1e18;

    // ─── senior helpers ──────────────────────────────────────────────────────

    /// @dev Live senior-side synced state (utilizations, effective NAVs, market state). `getState()` is stale marks.
    function _stSynced() internal view returns (SyncedAccountingState memory s) {
        (s,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
    }

    /// @dev One of the 4 ST-LP provider addresses (all hold ST_LP_ROLE + are funded in setUp).
    function _stLp(uint256 _idx) internal view returns (address) {
        address[4] memory lps = [ST_ALICE_ADDRESS, ST_BOB_ADDRESS, ST_CHARLIE_ADDRESS, ST_DAN_ADDRESS];
        return lps[_idx % 4];
    }

    /// @dev Seed a junior coverage buffer so senior deposits are possible (JT deposit is ungated in PERPETUAL).
    function _seedJT(uint256 _amount) internal returns (uint256 shares) {
        return _depositJT(JT_ALICE_ADDRESS, _amount);
    }

    /// @dev Deposit a raw TRANCHE_UNIT amount of ST (used for `maxDeposit`-boundary deposits).
    function _depositSTRaw(address _lp, TRANCHE_UNIT _assets) internal returns (uint256 shares) {
        vm.startPrank(_lp);
        IERC20(testConfig.stAsset).approve(address(ST), toUint256(_assets));
        shares = ST.deposit(_assets, _lp);
        vm.stopPrank();
    }

    /// @dev Redeem `_shares` of ST from `_lp` back to itself.
    function _redeemST(address _lp, uint256 _shares) internal returns (AssetClaims memory claims) {
        vm.prank(_lp);
        claims = ST.redeem(_shares, _lp, _lp);
    }

    /// @dev Senior share price in WAD (effective NAV per share). 0 when supply is 0.
    function _stSharePriceWAD() internal view returns (uint256) {
        uint256 supply = ST.totalSupply();
        if (supply == 0) return 0;
        return (toUint256(ST.totalAssets().nav) * WAD) / supply;
    }

    /// @dev Runs an accountant setter through its 2-day AccessManager execution delay while keeping the base->NAV feed
    ///      fresh across the warp (via the per-kernel `_refreshOraclesAfterWarp` seam). Without this, the 2-day warp
    ///      staleness-invalidates the real feed and the setter's `withSyncedAccounting` sync reverts.
    function _execAccountantSetterFresh(bytes memory _data) internal {
        _pinOracleFresh(); // freeze the feed's live value into the mock while it is still fresh (before the warp)

        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), _data, 0);

        vm.warp(block.timestamp + 2 days + 1);
        _refreshOraclesAfterWarp(); // re-stamp the mocked feed at the warped time so the setter's sync clears staleness

        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        ACCESS_MANAGER.execute(address(ACCOUNTANT), _data);
    }

    function _setMinCoverageFresh(uint64 _minCoverageWAD) internal {
        _execAccountantSetterFresh(abi.encodeCall(IRoycoDayAccountant.setMinCoverage, (_minCoverageWAD)));
    }

    function _setMinLiquidity(uint64 _minLiquidityWAD) internal {
        _execAccountantSetterFresh(abi.encodeCall(IRoycoDayAccountant.setMinLiquidity, (_minLiquidityWAD)));
    }

    function _setLiquidationCoverageUtilization(uint256 _wad) internal {
        _execAccountantSetterFresh(abi.encodeCall(IRoycoDayAccountant.setLiquidationCoverageUtilization, (_wad)));
    }

    /// @dev Best-effort attempt to force FIXED_TERM: a large senior drawdown covered by JT, then sync. Returns whether reached.
    function _tryEnterFixedTerm() internal returns (bool) {
        _seedJT(500_000e18);
        _depositST(_stLp(0), 100_000e18);
        simulateSTLoss(0.03e18); // 3% drawdown on the shared asset
        _sync();
        return _stSynced().marketState == MarketState.FIXED_TERM;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // A. DEPOSITS MINT THE CORRECT SHARES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice A senior deposit mints exactly the previewed shares and emits the exact-args `Deposit` event,
    ///         so the preview surface is the executable price.
    function test_deposit_mintsSharesEqualToPreview() external {
        _seedJT(200_000e18);
        address lp = _stLp(0);
        uint256 amount = 50_000e18;
        uint256 previewed = ST.previewDeposit(toTrancheUnits(amount));
        assertGt(previewed, 0, "arrange: the preview must be nonzero");

        vm.startPrank(lp);
        IERC20(testConfig.stAsset).approve(address(ST), amount);
        _expectDeposit(address(ST), lp, lp, toTrancheUnits(amount), previewed);
        uint256 minted = ST.deposit(toTrancheUnits(amount), lp);
        vm.stopPrank();

        assertEq(minted, previewed, "deposit shares must equal previewDeposit");
        assertEq(ST.balanceOf(lp), minted, "the receiver must hold the minted shares");
    }

    /// @notice `previewDeposit` is linear in the deposited amount up to floor dust, so a depositor cannot
    ///         change its price by splitting or merging deposits.
    function test_previewDeposit_proportionalToAmount() external {
        // Previews simulate the real deposit path, so JT coverage must exist for the quotes to clear the gate.
        _seedJT(200_000e18);
        // Each simulation unwinds, so both quotes price the same state: previewDeposit(2x) ~= 2 * previewDeposit(x) (floor split).
        uint256 x = 10_000e18;
        uint256 sx = ST.previewDeposit(toTrancheUnits(x));
        uint256 s2x = ST.previewDeposit(toTrancheUnits(2 * x));
        // Tolerance derivation: each preview composes two floor divisions (the asset -> NAV quote, then the
        // NAV -> share conversion). For a single floor, doubling the input drifts at most 1 unit from twice the
        // floored half (floor(2a) <= 2*floor(a) + 1), and a first-stage residue propagates through the second
        // stage at a near-1 price adding at most 1 more unit — two stages, at most 2 wei each, 4 wei total.
        assertApproxEqAbs(s2x, 2 * sx, 4, "previewDeposit must be ~proportional to amount");
    }

    /// @notice A fresh depositor's shares are redeemable for what it deposited, up to floor dust and never more.
    function test_deposit_redeemableValueMatchesDeposit() external {
        _seedJT(200_000e18);
        address lp = _stLp(0);
        uint256 amount = 40_000e18;

        NAV_UNIT depositedValue = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(amount));
        uint256 shares = _depositST(lp, amount);

        // A fresh depositor's shares are worth ~what they deposited — no windfall, no theft (down to floor dust).
        NAV_UNIT redeemable = ST.convertToAssets(shares).nav;
        assertApproxEqAbs(redeemable, depositedValue, maxNAVDelta(), "redeemable value must match deposited value");
        assertLe(redeemable, depositedValue, "depositor cannot gain vs deposited value");
    }

    /// @notice A later deposit never moves the senior share price: floor share pricing dilutes no one and
    ///         grants no windfall.
    function test_deposit_doesNotMoveSharePrice() external {
        // Seed some ST first so a share price exists, then a further deposit must not move it (no dilution, no windfall).
        _seedJT(300_000e18);
        _depositST(_stLp(0), 60_000e18);
        _sync();

        uint256 priceBefore = _stSharePriceWAD();
        uint256 supplyBefore = ST.totalSupply();
        _depositST(_stLp(1), 45_000e18);
        uint256 priceAfter = _stSharePriceWAD();

        // Derived bound: the booked raw delta can drift from the quoted deposit value by at most maxNAVDelta(),
        // which moves NAV-per-share by maxNAVDelta * WAD / supply; floor share pricing adds at most a wei each way
        uint256 priceTolerance = (toUint256(maxNAVDelta()) * WAD) / supplyBefore + 2;
        assertApproxEqAbs(priceAfter, priceBefore, priceTolerance, "a deposit must not move the senior share price beyond floor dust");
    }

    /// @notice A senior deposit raises the live collateral NAV (the raw mark BOTH coinvested tranches report)
    ///         by exactly the quoted deposit value, and conservation holds on the live marks.
    function test_deposit_increasesCollateralNAVByValue() external {
        _seedJT(200_000e18);
        uint256 amount = 50_000e18;
        NAV_UNIT value = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(amount));

        NAV_UNIT rawBefore = _liveCollateralNAV();
        _depositST(_stLp(0), amount);
        NAV_UNIT rawAfter = _liveCollateralNAV();

        assertApproxEqAbs(rawAfter, rawBefore + value, maxNAVDelta(), "the collateral NAV must rise by the deposited value");
        _assertNAVConservation();
    }

    /**
     * @notice Literal share-price anchor: the FIRST senior depositor mints shares 1:1 with its quoted deposit
     *         value, so the senior share price starts at exactly 1.0 — the hand constant 1e18 — rather than at
     *         whatever a pricing formula would produce.
     */
    function test_deposit_firstDepositorSharePriceIsOne() external {
        _seedJT(200_000e18);
        assertEq(ST.totalSupply(), 0, "arrange: the senior tranche must start empty for the 1:1 anchor");

        uint256 shares = _depositST(_stLp(0), 50_000e18);

        // Against zero supply the mint prices value 1:1, so NAV-per-share is 1e18 exactly, up to the drift between
        // the quoted value (which sized the mint) and the booked raw delta (which backs the shares). That drift is
        // at most maxNAVDelta(), moving the price by at most maxNAVDelta * WAD / shares, plus one floor wei.
        uint256 tolerance = (toUint256(maxNAVDelta()) * WAD) / shares + 1;
        assertApproxEqAbs(_stSharePriceWAD(), WAD, tolerance, "the first depositor's share price must anchor at exactly 1.0");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // B. DEPOSIT LIMITS FROM UTILIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice A deposit of exactly `maxDeposit` lands and leaves both utilization gates satisfied: the
    ///         reported maximum is actually depositable.
    function test_maxDeposit_boundaryDepositSucceeds() external {
        _seedJT(100_000e18);
        TRANCHE_UNIT max = ST.maxDeposit(_stLp(0));
        assertGt(max, toTrancheUnits(0), "max deposit must be positive once JT coverage exists");

        _depositSTRaw(_stLp(0), max);

        SyncedAccountingState memory s = _stSynced();
        assertLe(s.coverageUtilizationWAD, WAD, "coverageUtilizationWAD must stay <= WAD after a max deposit");
        assertLe(s.liquidityUtilizationWAD, WAD, "liquidityUtilizationWAD must stay <= WAD after a max deposit");
    }

    /// @notice A deposit far past `maxDeposit` reverts with the exact coverage-gate error.
    function test_RevertIf_DepositOverMax_BreachesCoverage() external {
        _seedJT(100_000e18);
        uint256 max = toUint256(ST.maxDeposit(_stLp(0)));

        // Clearly over the coverage limit (well beyond maxDeposit's documented dust-tolerance under-report).
        vm.startPrank(_stLp(0));
        IERC20(testConfig.stAsset).approve(address(ST), max + 100_000e18);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        ST.deposit(toTrancheUnits(max + 100_000e18), _stLp(0));
        vm.stopPrank();
    }

    /// @notice Raising the minimum coverage shrinks `maxSTDeposit` and a deposit sized to the old maximum
    ///         now reverts: the gate re-prices immediately after the parameter change.
    function test_deposit_tighterCoverageShrinksMaxAndBlocks() external {
        _seedJT(100_000e18);
        uint256 maxBefore = toUint256(ST.maxDeposit(_stLp(0)));

        _setMinCoverageFresh(0.5e18); // tighten coverage from 0.1e18 -> 0.5e18

        uint256 maxAfter = toUint256(ST.maxDeposit(_stLp(0)));
        assertLt(maxAfter, maxBefore, "tighter coverage must shrink maxSTDeposit");

        // A deposit sized to the OLD max now breaches the tighter coverage gate.
        vm.startPrank(_stLp(0));
        IERC20(testConfig.stAsset).approve(address(ST), maxBefore);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        ST.deposit(toTrancheUnits(maxBefore), _stLp(0));
        vm.stopPrank();
    }

    /// @notice With the market's baseline `minLiquidityWAD == 0` the liquidity metric reads zero and never
    ///         gates a senior deposit (the zero-minimum-liquidity reduction).
    function test_deposit_liquidityGateInertAtBaseline() external {
        // snUSD baseline has minLiquidity == 0, so the liquidity metric is 0 and never blocks a senior deposit.
        _seedJT(200_000e18);
        assertEq(_stSynced().minLiquidityWAD, 0, "baseline minLiquidity must be 0");

        _depositST(_stLp(0), 100_000e18);
        assertEq(_stSynced().liquidityUtilizationWAD, 0, "liquidityUtilizationWAD must stay 0 while minLiquidity == 0");
    }

    /**
     * @notice With a liquidity requirement set against zero pooled depth (`lptRawNAV == 0`) the liquidity
     *         utilization is unbounded, so every senior deposit reverts on the liquidity gate — pinning
     *         that senior deposits ARE liquidity-gated.
     */
    function test_RevertIf_DepositWithLiquidityRequirementAndEmptyPool() external {
        _seedJT(200_000e18);
        _setMinLiquidity(0.05e18);

        vm.startPrank(_stLp(0));
        IERC20(testConfig.stAsset).approve(address(ST), 50_000e18);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        ST.deposit(toTrancheUnits(50_000e18), _stLp(0));
        vm.stopPrank();
    }

    /// @notice In a fixed-term market a senior deposit reverts with the exact fixed-term-gate error and
    ///         `maxDeposit` reports zero (best-effort on a market whose config can reach FIXED_TERM).
    function test_RevertIf_DepositInFixedTerm() external {
        if (!_tryEnterFixedTerm()) {
            // snUSD runs with fixedTermDurationSeconds == 0 (permanently PERPETUAL), so FIXED_TERM is unreachable here.
            // The fixed-term deposit gate belongs to a state-machine suite on a market configured with a non-zero term.
            vm.skip(true);
            return;
        }
        assertEq(toUint256(ST.maxDeposit(_stLp(1))), 0, "maxDeposit must be 0 in FIXED_TERM");
        vm.startPrank(_stLp(1));
        IERC20(testConfig.stAsset).approve(address(ST), 10_000e18);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        ST.deposit(toTrancheUnits(10_000e18), _stLp(1));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // C. WITHDRAW (REDEEM) BEHAVIOR + LIMITS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice A partial senior redemption pays the pro-rata slice of the senior effective NAV and burns
    ///         exactly the redeemed shares.
    function test_redeem_returnsProportionalClaim() external {
        _seedJT(200_000e18);
        address lp = _stLp(0);
        uint256 shares = _depositST(lp, 80_000e18);
        _sync();

        uint256 supplyBefore = ST.totalSupply();
        NAV_UNIT effBefore = ST.totalAssets().nav;
        uint256 redeemShares = shares / 2;

        AssetClaims memory claims = _redeemST(lp, redeemShares);

        NAV_UNIT expected = NAV_UNIT.wrap((toUint256(effBefore) * redeemShares) / supplyBefore);
        assertApproxEqAbs(claims.nav, expected, maxNAVDelta(), "redeem claim NAV must be pro-rata to shares");
        assertEq(ST.totalSupply(), supplyBefore - redeemShares, "supply must drop by redeemed shares");
        _assertNAVConservation();
    }

    /**
     * @notice ADVERSARIAL — floor rounding on a redemption never favors the redeemer: an odd share count
     *         pays at most the exact pro-rata slice (never a wei more), so repeated dust redemptions cannot
     *         round-steal value from the remaining senior holders.
     */
    function test_redeem_floorRoundingNeverFavorsRedeemer() external {
        _seedJT(200_000e18);
        address lp = _stLp(0);
        uint256 shares = _depositST(lp, 80_000e18);
        _sync();

        uint256 supplyBefore = ST.totalSupply();
        NAV_UNIT effBefore = ST.totalAssets().nav;
        // A deliberately non-divisible share count so the pro-rata scaling must round
        uint256 redeemShares = shares / 3 + 1;

        AssetClaims memory claims = _redeemST(lp, redeemShares);

        // Exact pro-rata ceiling: floor(eff * shares / supply); the payout may only round DOWN from it
        uint256 proRata = (toUint256(effBefore) * redeemShares) / supplyBefore;
        assertLe(toUint256(claims.nav), proRata, "the redeemer can never be paid more than its exact pro-rata slice");
        assertGe(toUint256(claims.nav) + toUint256(maxNAVDelta()), proRata, "the rounding loss must stay within pricing dust");
        assertEq(ST.totalSupply(), supplyBefore - redeemShares, "supply must drop by exactly the redeemed shares");
        assertEq(ST.balanceOf(lp), shares - redeemShares, "the redeemer must burn exactly the redeemed shares");
        _assertNAVConservation();
    }

    /**
     * @notice Literal pro-rata anchors on a sole senior holder: half the supply can claim at most half the NAV
     *         (a hand halving, not the scaling formula), and the two halves of a full exit sum back to the whole
     *         pre-exit NAV within pricing dust — floor scaling neither leaks value to the exiter nor strands it.
     */
    function test_redeem_splitExitHalvesSumToWholeNAV() external {
        _seedJT(200_000e18);
        address lp = _stLp(0);
        uint256 shares = _depositST(lp, 80_000e18);
        _sync();
        assertEq(ST.totalSupply(), shares, "arrange: the redeemer must own the whole senior supply");

        NAV_UNIT wholeNAV = ST.totalAssets().nav;
        AssetClaims memory first = _redeemST(lp, shares / 2);
        // Hand-derived ceiling: floor rounding only goes down, and an odd share count redeems strictly less than
        // half the supply, so half the NAV bounds the first leg in every case.
        assertLe(toUint256(first.nav), toUint256(wholeNAV) / 2, "half the supply can never claim more than half the NAV");

        AssetClaims memory second = _redeemST(lp, shares - shares / 2);
        assertEq(ST.totalSupply(), 0, "the full exit must drain the senior supply");

        // Whole-equals-sum-of-parts: the two exits drain the entire tranche, so together they must recover the
        // whole pre-exit NAV. Each leg's booked raw delta can drift from its claim NAV by one pricing round-trip
        // in either direction, so allow one maxNAVDelta per leg plus a floor wei each way.
        uint256 recovered = toUint256(first.nav) + toUint256(second.nav);
        assertLe(recovered, toUint256(wholeNAV) + toUint256(maxNAVDelta()) + 1, "the split exit cannot recover more than the whole NAV plus pricing dust");
        assertGe(recovered + 2 * toUint256(maxNAVDelta()) + 2, toUint256(wholeNAV), "the split exit must recover the whole NAV up to pricing dust");
    }

    /// @notice Senior exits are never utilization-gated: a redemption succeeds with coverage parked at the brink.
    function test_redeem_notGatedByUtilization() external {
        // Push coverage near its limit, then redeem — ST redemption carries no coverage/liquidity gate, so it succeeds.
        _seedJT(100_000e18);
        address lp = _stLp(0);
        uint256 shares = _depositSTRaw(lp, ST.maxDeposit(lp)); // deposit up to the coverage limit
        _sync();
        // Threshold derivation: maxDeposit under-reports the exact coverage boundary only by the configured NAV
        // dust tolerances plus pricing conversion floors — wei-to-dust magnitudes against a deposit seeded in the
        // 1e22+ range — so a max-size deposit parks utilization within a sliver of 100%. A 0.9e18 floor sits far
        // above anything a failed arrange could read and far below the boundary, cleanly detecting "near the limit".
        assertGt(_stSynced().coverageUtilizationWAD, 0.9e18, "coverage should be near its limit after a max deposit");

        AssetClaims memory claims = _redeemST(lp, shares / 4);
        assertGt(claims.nav, NAV_UNIT.wrap(0), "ST redeem must succeed even with coverage near the limit");
    }

    /// @notice A full exit returns the deposited value up to floor dust and leaves the holder with zero shares.
    function test_redeem_fullExit() external {
        _seedJT(200_000e18);
        address lp = _stLp(0);
        NAV_UNIT deposited = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(70_000e18));
        uint256 shares = _depositST(lp, 70_000e18);
        _sync();

        AssetClaims memory claims = _redeemST(lp, shares);
        assertApproxEqAbs(claims.nav, deposited, maxNAVDelta(), "full exit must return ~the deposited value");
        assertEq(ST.balanceOf(lp), 0, "no ST shares must remain after a full exit");
    }

    /// @notice In a fixed-term market a senior redemption reverts with the exact fixed-term-gate error.
    function test_RevertIf_RedeemInFixedTerm() external {
        if (!_tryEnterFixedTerm()) {
            vm.skip(true); // fixedTermDurationSeconds == 0 for snUSD => permanently PERPETUAL; see the deposit variant
            return;
        }
        uint256 shares = ST.balanceOf(_stLp(0));
        vm.prank(_stLp(0));
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        ST.redeem(shares, _stLp(0), _stLp(0));
    }

    /// @notice Past the liquidation coverage utilization threshold a senior redemption pays a JT-funded
    ///         senior tranche self-liquidation bonus on top of its base claims.
    function test_Redeem_SelfLiquidationBonusAboveThreshold() external {
        _seedJT(100_000e18);
        address lp = _stLp(0);
        uint256 shares = _depositSTRaw(lp, ST.maxDeposit(lp));
        _sync();

        // Drop the liquidation threshold below the current coverage utilization so the self-liquidation regime engages.
        uint256 coverageUtilizationWAD = _stSynced().coverageUtilizationWAD;
        if (coverageUtilizationWAD <= WAD) {
            // The deposit gate caps coverageUtilizationWAD at WAD, and the liquidation threshold must be > WAD, so the self-liquidation
            // regime only engages after an asymmetric JT loss, which a shared-oracle market cannot produce.
            // Covered by a self-liquidation unit suite. Best-effort here.
            vm.skip(true);
            return;
        }
        _setLiquidationCoverageUtilization(coverageUtilizationWAD - 1);

        // The bonus leg no longer has its own claims field: it lands inside the single collateral leg. The
        // base claim is the exact pro-rata effective-NAV slice, so a payout strictly above that hand-derived
        // base is the JT-funded bonus.
        uint256 redeemShares = shares / 4;
        uint256 baseClaimNAV = (toUint256(ST.totalAssets().nav) * redeemShares) / ST.totalSupply();
        AssetClaims memory claims = _redeemST(lp, redeemShares);
        assertGt(toUint256(claims.nav), baseClaimNAV, "redeemer should receive a JT-funded self-liquidation bonus above the threshold");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // D. PREVIEW AND MAX FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice `previewRedeem` equals the executed redemption on every claims field in the same block, and the
    ///         `Redeem` event carries the previewed claims exactly.
    function test_previewRedeem_matchesExecution() external {
        _seedJT(200_000e18);
        address lp = _stLp(0);
        uint256 shares = _depositST(lp, 60_000e18);
        _sync();

        uint256 redeemShares = shares / 3;
        AssetClaims memory previewed = ST.previewRedeem(redeemShares);
        _expectRedeem(address(ST), lp, lp, previewed, redeemShares);
        AssetClaims memory executed = _redeemST(lp, redeemShares);

        assertEq(executed.nav, previewed.nav, "previewRedeem nav must equal executed nav");
        // The st/jt claim legs merged into the one collateral leg, so one field equality covers both.
        assertEq(executed.collateralAssets, previewed.collateralAssets, "previewRedeem collateralAssets must equal executed");
        assertEq(executed.lptAssets, previewed.lptAssets, "previewRedeem lptAssets must equal executed");
        assertEq(executed.stShares, previewed.stShares, "previewRedeem stShares must equal executed");
    }

    /// @notice `convertToShares` then `convertToAssets` round-trips a senior value with bounded floor loss and
    ///         never inflates it.
    function test_convertRoundTrip() external {
        _seedJT(200_000e18);
        _depositST(_stLp(0), 60_000e18);
        _sync();

        NAV_UNIT v = KERNEL.convertCollateralAssetsToValue(toTrancheUnits(25_000e18));
        uint256 shares = ST.convertToShares(_navToTU(v));
        NAV_UNIT back = ST.convertToAssets(shares).nav;
        assertLe(back, v, "convert round-trip cannot inflate value");
        assertApproxEqAbs(back, v, maxNAVDelta(), "convert round-trip must be lossless within floor dust");
    }

    /// @notice `maxRedeem` reports the holder's full balance in a healthy market and that maximum actually redeems.
    function test_maxRedeem_equalsShareBalance() external {
        // In a healthy PERPETUAL market ST withdrawable is not coverage-capped, so maxRedeem == the holder's balance.
        _seedJT(300_000e18);
        address lp = _stLp(0);
        uint256 shares = _depositST(lp, 50_000e18);
        _sync();

        assertEq(ST.maxRedeem(lp), shares, "maxRedeem must equal the holder's share balance in a healthy market");
        _redeemST(lp, ST.maxRedeem(lp)); // and it is fully redeemable
        assertEq(ST.balanceOf(lp), 0, "maxRedeem must be fully redeemable");
    }

    /// @notice While the kernel is paused both senior max views report zero: the pause blast radius covers
    ///         the whole deposit/redeem surface.
    function test_maxDeposit_maxRedeem_zeroWhenPaused() external {
        _seedJT(200_000e18);
        address lp = _stLp(0);
        _depositST(lp, 40_000e18);

        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(KERNEL)).pause();

        assertEq(toUint256(ST.maxDeposit(lp)), 0, "maxDeposit must be 0 while paused");
        assertEq(ST.maxRedeem(lp), 0, "maxRedeem must be 0 while paused");
    }

    /// @dev Convert a NAV_UNIT value back to TRANCHE_UNIT via the kernel (inverse of `convertCollateralAssetsToValue`).
    function _navToTU(NAV_UNIT _value) internal view returns (TRANCHE_UNIT) {
        return KERNEL.convertValueToCollateralAssets(_value);
    }
}
