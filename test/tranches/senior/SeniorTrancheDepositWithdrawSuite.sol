// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { AssetClaims, MarketState, SyncedAccountingState, TrancheType } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { Identical_ERC4626_Chainlink_BalancerV3_LT_KernelTest } from
    "../../kernels/Identical_ERC4626_Chainlink_BalancerV3_LT/base/Identical_ERC4626_Chainlink_BalancerV3_LT_KernelTest.sol";

/**
 * @title SeniorTrancheDepositWithdrawSuite
 * @notice Abstract deposit/withdraw test battery for the SENIOR tranche, run against a real forked market. A concrete
 *         per-market test instantiates it by inheriting both this suite and a market fixture (e.g. `Neutrl_snUSD_Market`);
 *         both share `AbstractKernelTestSuite` as the deploy/setUp base.
 * @dev Covers the user's three concerns: (A) deposits mint the correct shares, (B) deposit/withdraw limits from the
 *      coverage + liquidity utilization gates, and (C) the preview/max view surface. Senior mechanics pinned:
 *      - ST deposit: PERPETUAL-only; post-op coverage gate (`COVERAGE_REQUIREMENT_VIOLATED`) AND liquidity gate
 *        (`LIQUIDITY_REQUIREMENT_VIOLATED`); `maxSTDeposit = min(coverage-branch, liquidity-branch)`.
 *      - ST redeem: PERPETUAL-only; NO coverage/liquidity gate; self-liquidation bonus once `covUtil >= liqThreshold`.
 *      A senior deposit needs a junior coverage buffer to exist first, so tests seed JT before depositing ST.
 *
 *      Coinvested-market caveat: for the snUSD market ST and JT share one asset + one base->NAV feed, so the `simulate*`
 *      hooks move both legs together. FIXED_TERM / self-liq-bonus tests are therefore best-effort: they attempt to reach
 *      the target state and `vm.skip` (with a reason) if a symmetric-PnL market cannot get there.
 */
abstract contract SeniorTrancheDepositWithdrawSuite is Identical_ERC4626_Chainlink_BalancerV3_LT_KernelTest {
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

    function test_deposit_mintsSharesEqualToPreview() external {
        _seedJT(200_000e18);
        address lp = _stLp(0);
        uint256 amount = 50_000e18;

        uint256 previewed = ST.previewDeposit(toTrancheUnits(amount));
        uint256 minted = _depositST(lp, amount);

        assertEq(minted, previewed, "deposit shares must equal previewDeposit");
        assertGt(minted, 0, "must mint non-zero shares");
    }

    function test_previewDeposit_proportionalToAmount() external view {
        // Views on the un-mutated state: previewDeposit(2x) ~= 2 * previewDeposit(x) (floor split).
        uint256 x = 10_000e18;
        uint256 sx = ST.previewDeposit(toTrancheUnits(x));
        uint256 s2x = ST.previewDeposit(toTrancheUnits(2 * x));
        // proportional within a few wei of floor dust
        assertApproxEqAbs(s2x, 2 * sx, 4, "previewDeposit must be ~proportional to amount");
    }

    function test_deposit_redeemableValueMatchesDeposit() external {
        _seedJT(200_000e18);
        address lp = _stLp(0);
        uint256 amount = 40_000e18;

        NAV_UNIT depositedValue = _toSTValue(toTrancheUnits(amount));
        uint256 shares = _depositST(lp, amount);

        // A fresh depositor's shares are worth ~what they deposited — no windfall, no theft (down to floor dust).
        NAV_UNIT redeemable = ST.convertToAssets(shares).nav;
        assertApproxEqAbs(redeemable, depositedValue, maxNAVDelta(), "redeemable value must match deposited value");
        assertLe(redeemable, depositedValue, "depositor cannot gain vs deposited value");
    }

    function test_deposit_doesNotMoveSharePrice() external {
        // Seed some ST first so a share price exists, then a further deposit must not move it (no dilution, no windfall).
        _seedJT(300_000e18);
        _depositST(_stLp(0), 60_000e18);
        _sync();

        uint256 priceBefore = _stSharePriceWAD();
        _depositST(_stLp(1), 45_000e18);
        uint256 priceAfter = _stSharePriceWAD();

        assertApproxEqAbs(priceAfter, priceBefore, 1e6, "a deposit must not move the senior share price beyond floor dust");
    }

    function test_deposit_increasesRawNAVByValue() external {
        _seedJT(200_000e18);
        uint256 amount = 50_000e18;
        NAV_UNIT value = _toSTValue(toTrancheUnits(amount));

        NAV_UNIT rawBefore = ST.getRawNAV();
        _depositST(_stLp(0), amount);
        NAV_UNIT rawAfter = ST.getRawNAV();

        assertApproxEqAbs(rawAfter, rawBefore + value, maxNAVDelta(), "stRawNAV must rise by the deposited value");
        _assertNAVConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // B. DEPOSIT LIMITS FROM UTILIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_maxDeposit_boundaryDepositSucceeds() external {
        _seedJT(100_000e18);
        TRANCHE_UNIT max = ST.maxDeposit(_stLp(0));
        assertGt(max, toTrancheUnits(0), "max deposit must be positive once JT coverage exists");

        _depositSTRaw(_stLp(0), max);

        SyncedAccountingState memory s = _stSynced();
        assertLe(s.coverageUtilizationWAD, WAD, "covUtil must stay <= WAD after a max deposit");
        assertLe(s.liquidityUtilizationWAD, WAD, "liqUtil must stay <= WAD after a max deposit");
    }

    function test_deposit_overMaxRevertsCoverage() external {
        _seedJT(100_000e18);
        uint256 max = toUint256(ST.maxDeposit(_stLp(0)));

        // Clearly over the coverage limit (well beyond the F15 dust slack).
        vm.startPrank(_stLp(0));
        IERC20(testConfig.stAsset).approve(address(ST), max + 100_000e18);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        ST.deposit(toTrancheUnits(max + 100_000e18), _stLp(0));
        vm.stopPrank();
    }

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

    function test_deposit_liquidityGateInertAtBaseline() external {
        // snUSD baseline has minLiquidity == 0, so the liquidity metric is 0 and never blocks a senior deposit.
        _seedJT(200_000e18);
        assertEq(_stSynced().minLiquidityWAD, 0, "baseline minLiquidity must be 0");

        _depositST(_stLp(0), 100_000e18);
        assertEq(_stSynced().liquidityUtilizationWAD, 0, "liqUtil must stay 0 while minLiquidity == 0");
    }

    function test_deposit_liquidityGateBindsWhenMinLiquiditySet() external {
        // Turning on a liquidity requirement with no pooled depth (ltRaw == 0) makes liqUtil unbounded, so an ST deposit
        // is blocked on the liquidity gate — pinning that ST deposits ARE liquidity-gated (testing-strategy Appendix B.1).
        _seedJT(200_000e18);
        _setMinLiquidity(0.05e18);

        vm.startPrank(_stLp(0));
        IERC20(testConfig.stAsset).approve(address(ST), 50_000e18);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        ST.deposit(toTrancheUnits(50_000e18), _stLp(0));
        vm.stopPrank();
    }

    function test_deposit_revertsInFixedTerm() external {
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

    function test_redeem_notGatedByUtilization() external {
        // Push coverage near its limit, then redeem — ST redemption carries no coverage/liquidity gate, so it succeeds.
        _seedJT(100_000e18);
        address lp = _stLp(0);
        uint256 shares = _depositSTRaw(lp, ST.maxDeposit(lp)); // deposit up to the coverage limit
        _sync();
        assertGt(_stSynced().coverageUtilizationWAD, 0.9e18, "coverage should be near its limit after a max deposit");

        AssetClaims memory claims = _redeemST(lp, shares / 4);
        assertGt(claims.nav, NAV_UNIT.wrap(0), "ST redeem must succeed even with coverage near the limit");
    }

    function test_redeem_fullExit() external {
        _seedJT(200_000e18);
        address lp = _stLp(0);
        NAV_UNIT deposited = _toSTValue(toTrancheUnits(70_000e18));
        uint256 shares = _depositST(lp, 70_000e18);
        _sync();

        AssetClaims memory claims = _redeemST(lp, shares);
        assertApproxEqAbs(claims.nav, deposited, maxNAVDelta(), "full exit must return ~the deposited value");
        assertEq(ST.balanceOf(lp), 0, "no ST shares must remain after a full exit");
    }

    function test_redeem_revertsInFixedTerm() external {
        if (!_tryEnterFixedTerm()) {
            vm.skip(true); // fixedTermDurationSeconds == 0 for snUSD => permanently PERPETUAL; see the deposit variant
            return;
        }
        uint256 shares = ST.balanceOf(_stLp(0));
        vm.prank(_stLp(0));
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        ST.redeem(shares, _stLp(0), _stLp(0));
    }

    function test_redeem_selfLiqBonusAboveThreshold() external {
        _seedJT(100_000e18);
        address lp = _stLp(0);
        uint256 shares = _depositSTRaw(lp, ST.maxDeposit(lp));
        _sync();

        // Drop the liquidation threshold below the current coverage utilization so the self-liquidation regime engages.
        uint256 covUtil = _stSynced().coverageUtilizationWAD;
        if (covUtil <= WAD) {
            // The deposit gate caps covUtil at WAD, and the liquidation threshold must be > WAD, so the self-liquidation
            // regime only engages after an asymmetric JT loss — which a coinvested shared-oracle market cannot produce.
            // Covered by a self-liquidation unit suite (or a non-coinvested market). Best-effort here.
            vm.skip(true);
            return;
        }
        _setLiquidationCoverageUtilization(covUtil - 1);

        AssetClaims memory claims = _redeemST(lp, shares / 4);
        assertGt(claims.jtAssets, toTrancheUnits(0), "redeemer should receive a JT-funded self-liquidation bonus above the threshold");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // D. PREVIEW AND MAX FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_previewRedeem_matchesExecution() external {
        _seedJT(200_000e18);
        address lp = _stLp(0);
        uint256 shares = _depositST(lp, 60_000e18);
        _sync();

        uint256 redeemShares = shares / 3;
        AssetClaims memory previewed = ST.previewRedeem(redeemShares);
        AssetClaims memory executed = _redeemST(lp, redeemShares);

        assertEq(executed.nav, previewed.nav, "previewRedeem nav must equal executed nav");
        assertEq(executed.stAssets, previewed.stAssets, "previewRedeem stAssets must equal executed");
        assertEq(executed.jtAssets, previewed.jtAssets, "previewRedeem jtAssets must equal executed");
    }

    function test_convertRoundTrip() external {
        _seedJT(200_000e18);
        _depositST(_stLp(0), 60_000e18);
        _sync();

        NAV_UNIT v = _toSTValue(toTrancheUnits(25_000e18));
        uint256 shares = ST.convertToShares(_navToTU(v));
        NAV_UNIT back = ST.convertToAssets(shares).nav;
        assertLe(back, v, "convert round-trip cannot inflate value");
        assertApproxEqAbs(back, v, maxNAVDelta(), "convert round-trip must be lossless within floor dust");
    }

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

    function test_maxDeposit_maxRedeem_zeroWhenPaused() external {
        _seedJT(200_000e18);
        address lp = _stLp(0);
        _depositST(lp, 40_000e18);

        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(KERNEL)).pause();

        assertEq(toUint256(ST.maxDeposit(lp)), 0, "maxDeposit must be 0 while paused");
        assertEq(ST.maxRedeem(lp), 0, "maxRedeem must be 0 while paused");
    }

    /// @dev Convert a NAV_UNIT senior value back to TRANCHE_UNIT via the kernel (inverse of `_toSTValue`).
    function _navToTU(NAV_UNIT _value) internal view returns (TRANCHE_UNIT) {
        return KERNEL.stConvertNAVUnitsToTrancheUnits(_value);
    }
}
