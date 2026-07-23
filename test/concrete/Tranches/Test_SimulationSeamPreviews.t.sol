// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { DispatchLogic } from "../../../src/libraries/logic/DispatchLogic.sol";
import { AssetClaims, MarketState, Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MarketFuzzTestBase } from "../../utils/MarketFuzzTestBase.sol";

/**
 * @title SimulationSeamPreviewsTestBase
 * @notice Shared scaffolding for the execute-and-revert preview seam suites: a full-market state snapshot the
 *         neutrality assertions diff, and the byte-exact claims parity helper the redemption parities share
 * @dev previewDeposit and previewRedeem now run the REAL mutating kernel flow inside a self-call frame and unwind
 *      it via a result-carrying revert, so the spec under test is preview == exec exactly, minus asset custody,
 *      share mint/burn, allowance, and the receiver. Every assertion below is derived from that spec
 */
abstract contract SimulationSeamPreviewsTestBase is MarketFuzzTestBase {
    using Math for uint256;

    /// @dev Everything a preview could illegally touch: both accounting checkpoints, all three share supplies,
    ///      the kernel's custody balances (including staged premium senior shares), and the venue's own ledger
    struct MarketSnapshot {
        bytes32 kernelStateHash;
        bytes32 accountantStateHash;
        uint256 stSupply;
        uint256 jtSupply;
        uint256 ltSupply;
        uint256 kernelVaultShareBalance;
        uint256 kernelBPTBalance;
        uint256 kernelSTShareBalance;
        uint256 bptTotalSupply;
        uint256 venueQuoteBalance;
    }

    /// @notice Captures the full mutable market surface a preview must leave untouched
    function _snapshotMarket() internal view returns (MarketSnapshot memory s) {
        s.kernelStateHash = keccak256(abi.encode(kernel.getState()));
        s.accountantStateHash = keccak256(abi.encode(accountant.getState()));
        s.stSupply = seniorTranche.totalSupply();
        s.jtSupply = juniorTranche.totalSupply();
        s.ltSupply = liquidityTranche.totalSupply();
        s.kernelVaultShareBalance = stJtVault.balanceOf(address(kernel));
        s.kernelBPTBalance = bpt.balanceOf(address(kernel));
        s.kernelSTShareBalance = seniorTranche.balanceOf(address(kernel));
        s.bptTotalSupply = bpt.totalSupply();
        s.venueQuoteBalance = quoteToken.balanceOf(address(balancerVault));
    }

    /// @notice Asserts the live market state is byte-identical to the pre-preview snapshot, field by field so a
    ///         leak names exactly what bled through the revert-unwind
    function _assertSnapshotUnchanged(MarketSnapshot memory _before, string memory _ctx) internal view {
        MarketSnapshot memory a = _snapshotMarket();
        assertEq(a.kernelStateHash, _before.kernelStateHash, string.concat(_ctx, ": kernel owned-asset counters must be untouched"));
        assertEq(a.accountantStateHash, _before.accountantStateHash, string.concat(_ctx, ": accountant checkpoints must be untouched"));
        assertEq(a.stSupply, _before.stSupply, string.concat(_ctx, ": senior supply must be untouched"));
        assertEq(a.jtSupply, _before.jtSupply, string.concat(_ctx, ": junior supply must be untouched"));
        assertEq(a.ltSupply, _before.ltSupply, string.concat(_ctx, ": liquidity supply must be untouched"));
        assertEq(a.kernelVaultShareBalance, _before.kernelVaultShareBalance, string.concat(_ctx, ": kernel vault-share custody must be untouched"));
        assertEq(a.kernelBPTBalance, _before.kernelBPTBalance, string.concat(_ctx, ": kernel BPT custody must be untouched"));
        assertEq(a.kernelSTShareBalance, _before.kernelSTShareBalance, string.concat(_ctx, ": kernel staged senior shares must be untouched"));
        assertEq(a.bptTotalSupply, _before.bptTotalSupply, string.concat(_ctx, ": venue BPT supply must be untouched"));
        assertEq(a.venueQuoteBalance, _before.venueQuoteBalance, string.concat(_ctx, ": venue quote ledger must be untouched"));
    }

    /// @notice Asserts all five claim legs of an executed redemption equal the same-block preview byte-for-byte
    function _assertClaimsParity(AssetClaims memory _executed, AssetClaims memory _previewed, string memory _flow) internal pure {
        assertEq(_executed.stAssets, _previewed.stAssets, string.concat(_flow, ": senior-asset leg must match the preview"));
        assertEq(_executed.jtAssets, _previewed.jtAssets, string.concat(_flow, ": junior-asset leg must match the preview"));
        assertEq(_executed.ltAssets, _previewed.ltAssets, string.concat(_flow, ": LT-asset leg must match the preview"));
        assertEq(_executed.stShares, _previewed.stShares, string.concat(_flow, ": senior-share leg must match the preview"));
        assertEq(_executed.nav, _previewed.nav, string.concat(_flow, ": claim NAV must match the preview"));
    }
}

/**
 * @title Test_SimulationSeamPreviews_Tranches
 * @notice Spec-first coverage of the execute-and-revert preview seam on all three tranches: exact preview/exec
 *         parity for deposits and redemptions (fresh market, pending-mint yield states, and the liquidation
 *         regime with the ST self-liquidation bonus), full state neutrality of both previews, verbatim revert
 *         bubbling (pause, zero amounts), and the ONLY_SELF gate on the simulation callbacks
 * @dev Seeded once per test in setUp so every literal below is wei-exact: ST 100e18 and JT 30e18 vault shares at
 *      a 1.0 rate (coverage (100 + 30) x 0.2 / 30 = 0.8667 <= 1) plus the auto-seeded quote-only LT depth of
 *      exactly 6e18 NAV (required ceil(100e18 x 0.05) = 5e18 in whole quote wei plus one whole-quote cushion),
 *      so every tranche starts at a 1.0 share price
 */
contract Test_SimulationSeamPreviews_Tranches is SimulationSeamPreviewsTestBase {
    function setUp() public override {
        super.setUp();
        _seedFlatMarket(100e18, 30e18, 0);
    }

    // =============================
    // Deposit parity (spec: previewDeposit(assets) == shares minted by deposit(assets, receiver) in the same block)
    // =============================

    /**
     * @notice On the flat seeded market every deposit preview quotes the exact 1:1 mint and the same-block
     *         execution mints exactly the previewed shares on all three tranches
     * @dev All rates are 1.0 so each quote is pinned absolutely, not just relatively, under the virtual-shares/assets
     *      offset the mint carries (floor((supply + 1e6) x value / (effNAV + 1))): ST 10e18 assets = 10e18 NAV against
     *      100e18 effective NAV over 100e18 shares mints floor((100e18 + 1e6) x 10e18 / (100e18 + 1)) = 10000000000000099999,
     *      JT the same at 30e18 over 30e18 mints floor((30e18 + 1e6) x 10e18 / (30e18 + 1)) = 10000000000000333332, and LT
     *      5e18 quote-backed BPT (NAV-per-BPT 1.0) against 6e18 effective NAV over 6e18 shares mints
     *      floor((6e18 + 1e6) x 5e18 / (6e18 + 1)) = 5000000000000833332
     */
    function test_PreviewDeposit_FreshMarket_ExactQuotesAndExecParity() public {
        uint256 stPreviewed = seniorTranche.previewDeposit(toTrancheUnits(10e18));
        assertEq(stPreviewed, 10000000000000099999, "the flat-market senior quote must be the exact offset-adjusted mint");
        assertEq(_depositSenior(10e18), stPreviewed, "the senior deposit must mint exactly the previewed shares");

        uint256 jtPreviewed = juniorTranche.previewDeposit(toTrancheUnits(10e18));
        assertEq(jtPreviewed, 10000000000000333332, "the flat-market junior quote must be the exact offset-adjusted mint");
        assertEq(_depositJunior(10e18), jtPreviewed, "the junior deposit must mint exactly the previewed shares");

        _mintQuoteBackedBPT(LT_PROVIDER, 5e18, 5e6);
        uint256 ltPreviewed = liquidityTranche.previewDeposit(toTrancheUnits(5e18));
        assertEq(ltPreviewed, 5000000000000833332, "the flat-market liquidity quote must be the exact offset-adjusted mint");
        vm.startPrank(LT_PROVIDER);
        bpt.approve(address(liquidityTranche), 5e18);
        assertEq(liquidityTranche.deposit(toTrancheUnits(5e18), LT_PROVIDER), ltPreviewed, "the liquidity deposit must mint exactly the previewed shares");
        vm.stopPrank();
    }

    /**
     * @notice With accrued yield and its premium and protocol fee mints still PENDING (no sync since the accrual),
     *         each deposit preview matches its same-block execution exactly on all three tranches
     * @dev This is the state the old view previews mispriced: the quote must be minted-share-exact only if the
     *      simulation runs the real pre-op sync (fee shares to the recipient, the premium's senior-share mint and
     *      single-sided venue deploy) and prices against the post-sync supply, exactly as execution will
     */
    function test_PreviewDeposit_PendingPremiumAndFeeMints_MatchesExec() public {
        applySTPnL(1000);
        _warpAndRefreshFeed(30 days);
        syncVenuePrices();

        uint256 stPreviewed = seniorTranche.previewDeposit(toTrancheUnits(10e18));
        assertEq(_depositSenior(10e18), stPreviewed, "the senior deposit must mint exactly the shares previewed under pending mints");

        uint256 jtPreviewed = juniorTranche.previewDeposit(toTrancheUnits(10e18));
        assertEq(_depositJunior(10e18), jtPreviewed, "the junior deposit must mint exactly the shares previewed under pending mints");

        _mintQuoteBackedBPT(LT_PROVIDER, 5e18, 5e6);
        uint256 ltPreviewed = liquidityTranche.previewDeposit(toTrancheUnits(5e18));
        vm.startPrank(LT_PROVIDER);
        bpt.approve(address(liquidityTranche), 5e18);
        assertEq(
            liquidityTranche.deposit(toTrancheUnits(5e18), LT_PROVIDER),
            ltPreviewed,
            "the liquidity deposit must mint exactly the shares previewed under pending mints"
        );
        vm.stopPrank();
    }

    // =============================
    // Redeem parity (spec: previewRedeem(shares) claims == redeem(shares, receiver, owner) claims in the same block)
    // =============================

    /**
     * @notice On the flat seeded market every redemption preview quotes the exact pro-rata claims and the
     *         same-block execution pays exactly the previewed claims on every leg, on all three tranches
     * @dev All value sits on each tranche's own raw NAV at a 1.0 rate, and the claim scaler carries the virtual-shares
     *      offset (floor(leg x shares / (supply + 1e6)), leaving a virtual-dust sliver): 10e18 ST shares of 100e18
     *      supply claim floor(100e18 x 10e18 / (100e18 + 1e6)) = 9999999999999900000 senior assets and NAV, 5e18 JT
     *      shares of 30e18 claim floor(30e18 x 5e18 / (30e18 + 1e6)) = 4999999999999833333, 1e18 LT shares of 6e18
     *      claim floor(6e18 x 1e18 / (6e18 + 1e6)) = 999999999999833333 BPT. The LT slice is sized so the
     *      post-redemption depth 5e18 clears the 5% liquidity floor on the post-exit senior effective NAV of 90e18 (required 4.5e18)
     */
    function test_PreviewRedeem_FreshMarket_ExactQuotesAndExecParity() public {
        AssetClaims memory stPreviewed = seniorTranche.previewRedeem(10e18);
        assertEq(stPreviewed.stAssets, toTrancheUnits(9999999999999900000), "the senior quote must claim exactly its pro-rata senior assets");
        assertEq(stPreviewed.nav, toNAVUnits(uint256(9999999999999900000)), "the senior quote must claim exactly its pro-rata NAV");
        vm.prank(ST_PROVIDER);
        AssetClaims memory stClaims = seniorTranche.redeem(10e18, ST_PROVIDER, ST_PROVIDER);
        _assertClaimsParity(stClaims, stPreviewed, "senior redemption");

        AssetClaims memory jtPreviewed = juniorTranche.previewRedeem(5e18);
        assertEq(jtPreviewed.jtAssets, toTrancheUnits(4999999999999833333), "the junior quote must claim exactly its pro-rata junior assets");
        assertEq(jtPreviewed.nav, toNAVUnits(uint256(4999999999999833333)), "the junior quote must claim exactly its pro-rata NAV");
        vm.prank(JT_PROVIDER);
        AssetClaims memory jtClaims = juniorTranche.redeem(5e18, JT_PROVIDER, JT_PROVIDER);
        _assertClaimsParity(jtClaims, jtPreviewed, "junior redemption");

        AssetClaims memory ltPreviewed = liquidityTranche.previewRedeem(1e18);
        assertEq(ltPreviewed.ltAssets, toTrancheUnits(999999999999833333), "the liquidity quote must claim exactly its pro-rata BPT");
        assertEq(ltPreviewed.nav, toNAVUnits(uint256(999999999999833333)), "the liquidity quote must claim exactly its pro-rata NAV");
        vm.prank(LT_PROVIDER);
        AssetClaims memory ltClaims = liquidityTranche.redeem(1e18, LT_PROVIDER, LT_PROVIDER);
        _assertClaimsParity(ltClaims, ltPreviewed, "liquidity redemption");
    }

    /**
     * @notice With accrued yield and its premium and fee mints still pending, each redemption preview matches its
     *         same-block execution exactly on every claim leg, on all three tranches
     * @dev The simulated redemption must run the identical pre-op sync (committing the pending mints and the
     *      premium's venue deploy) and read the identical pre-burn supply, or a leg diverges here
     */
    function test_PreviewRedeem_PendingPremiumAndFeeMints_MatchesExec() public {
        applySTPnL(1000);
        _warpAndRefreshFeed(30 days);
        syncVenuePrices();

        uint256 stShares = seniorTranche.maxRedeem(ST_PROVIDER) / 2;
        AssetClaims memory stPreviewed = seniorTranche.previewRedeem(stShares);
        vm.prank(ST_PROVIDER);
        AssetClaims memory stClaims = seniorTranche.redeem(stShares, ST_PROVIDER, ST_PROVIDER);
        _assertClaimsParity(stClaims, stPreviewed, "senior redemption under pending mints");

        uint256 jtShares = juniorTranche.maxRedeem(JT_PROVIDER) / 2;
        AssetClaims memory jtPreviewed = juniorTranche.previewRedeem(jtShares);
        vm.prank(JT_PROVIDER);
        AssetClaims memory jtClaims = juniorTranche.redeem(jtShares, JT_PROVIDER, JT_PROVIDER);
        _assertClaimsParity(jtClaims, jtPreviewed, "junior redemption under pending mints");

        uint256 ltShares = liquidityTranche.maxRedeem(LT_PROVIDER) / 2;
        AssetClaims memory ltPreviewed = liquidityTranche.previewRedeem(ltShares);
        vm.prank(LT_PROVIDER);
        AssetClaims memory ltClaims = liquidityTranche.redeem(ltShares, LT_PROVIDER, LT_PROVIDER);
        _assertClaimsParity(ltClaims, ltPreviewed, "liquidity redemption under pending mints");
    }

    /**
     * @notice In the liquidation regime the senior redemption preview quotes the pro-rata claims PLUS the exact
     *         self-liquidation bonus, and the same-block execution pays exactly the previewed claims
     * @dev A covered -21% drawdown marks coverage utilization at ceil(102.7e18 x 0.2 / 2.7e18) = 7.608e18, past
     *      the 6.4667e18 liquidation threshold, which forces the market PERPETUAL with the bonus armed. The loss
     *      is fully covered so 10e18 of the 100e18 senior shares claim a base NAV of floor(100e18 x 10e18 /
     *      (100e18 + 1e6)) = 9999999999999900000 (the virtual-shares offset), the sized bonus is
     *      min(configured 1% x base = base / 100, junior buffer 2.7e18, neutral cap base x 2.7 / 100) =
     *      99999999999999000, and the report is the value of the granted assets: floor(floor(99999999999999000 /
     *      0.79) x 0.79) = 99999999999998999, so the previewed claim NAV must be exactly 9999999999999900000 +
     *      99999999999998999 = 10099999999999898999 and execution must match it on every leg
     */
    function test_PreviewRedeem_LiquidationRegime_SelfLiquidationBonusParity() public {
        applySTPnL(-2100);
        SyncedAccountingState memory state = _sync();
        assertGe(state.coverageUtilizationWAD, state.coverageLiquidationUtilizationWAD, "the drawdown must breach the liquidation coverage threshold");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "a liquidation breach forces the market PERPETUAL so the redemption stays open");

        AssetClaims memory previewed = seniorTranche.previewRedeem(10e18);
        assertEq(previewed.nav, toNAVUnits(uint256(10099999999999898999)), "the quote must carry the base 9999999999999900000 slice plus the asset-quantized 99999999999998999 bonus");

        vm.prank(ST_PROVIDER);
        AssetClaims memory claims = seniorTranche.redeem(10e18, ST_PROVIDER, ST_PROVIDER);
        _assertClaimsParity(claims, previewed, "bonus-boosted senior redemption");
    }

    // =============================
    // State neutrality (spec: both previews change NOTHING)
    // =============================

    /**
     * @notice Running every preview on every tranche leaves the entire market state byte-identical, even when the
     *         simulated frame commits pending premium and fee mints and a venue deploy before unwinding
     * @dev The pending-mint state maximizes what the simulation mutates inside its frame (fee share mints, the
     *      premium senior-share mint, the single-sided venue add, every checkpoint write), so this pins that the
     *      result-carrying revert unwinds all of it: checkpoints, supplies, custody, and the venue ledger
     */
    function test_StateNeutrality_PreviewsMutateNothing() public {
        applySTPnL(1000);
        _warpAndRefreshFeed(30 days);
        syncVenuePrices();

        // Redemption slices come from the live liquidity-respecting maxes so the simulated exits clear every gate
        uint256 stShares = seniorTranche.maxRedeem(ST_PROVIDER) / 2;
        uint256 jtShares = juniorTranche.maxRedeem(JT_PROVIDER) / 2;
        uint256 ltShares = liquidityTranche.maxRedeem(LT_PROVIDER) / 2;
        assertGt(stShares * jtShares * ltShares, 0, "arrange: every tranche must have a redeemable slice to simulate");

        MarketSnapshot memory before = _snapshotMarket();

        seniorTranche.previewDeposit(toTrancheUnits(10e18));
        _assertSnapshotUnchanged(before, "senior previewDeposit");
        juniorTranche.previewDeposit(toTrancheUnits(10e18));
        _assertSnapshotUnchanged(before, "junior previewDeposit");
        liquidityTranche.previewDeposit(toTrancheUnits(5e18));
        _assertSnapshotUnchanged(before, "liquidity previewDeposit");

        seniorTranche.previewRedeem(stShares);
        _assertSnapshotUnchanged(before, "senior previewRedeem");
        juniorTranche.previewRedeem(jtShares);
        _assertSnapshotUnchanged(before, "junior previewRedeem");
        liquidityTranche.previewRedeem(ltShares);
        _assertSnapshotUnchanged(before, "liquidity previewRedeem");
    }

    /**
     * @notice Two consecutive previews agree exactly and the execution that follows in the same block still pays
     *         exactly the first preview's quote, so a preview leaves nothing behind that reprices the next call
     * @dev Runs on the pending-mint state so the simulated frame commits real mints before unwinding: any bleed
     *      (a stale checkpoint, a leaked supply change) would split the double previews or shift the execution
     */
    function test_NoStateBleed_ConsecutivePreviewsAgreeAndExecMatchesFirstQuote() public {
        applySTPnL(500);
        _warpAndRefreshFeed(7 days);
        syncVenuePrices();

        uint256 firstDepositQuote = seniorTranche.previewDeposit(toTrancheUnits(10e18));
        uint256 secondDepositQuote = seniorTranche.previewDeposit(toTrancheUnits(10e18));
        assertEq(secondDepositQuote, firstDepositQuote, "back-to-back deposit previews must agree exactly");
        assertEq(_depositSenior(10e18), firstDepositQuote, "the execution must mint exactly the first previewed quote");

        AssetClaims memory firstRedeemQuote = seniorTranche.previewRedeem(10e18);
        AssetClaims memory secondRedeemQuote = seniorTranche.previewRedeem(10e18);
        assertEq(
            keccak256(abi.encode(secondRedeemQuote)), keccak256(abi.encode(firstRedeemQuote)), "back-to-back redeem previews must agree on every claim leg"
        );
        vm.prank(ST_PROVIDER);
        AssetClaims memory claims = seniorTranche.redeem(10e18, ST_PROVIDER, ST_PROVIDER);
        _assertClaimsParity(claims, firstRedeemQuote, "post-preview senior redemption");
    }

    // =============================
    // Revert parity (spec: every revert exec would raise bubbles from the preview unchanged)
    // =============================

    /**
     * @notice A zero-asset deposit preview bubbles the exact error the zero-asset execution raises on all three
     *         tranches, and a zero-share redeem preview bubbles the exact zero-share execution error
     * @dev A zero deposit moves its tranche's raw NAV by zero, so the kernel's post-operation validation rejects
     *      it with the op-tagged INVALID_POST_OP_STATE before any tranche-level guard. The zero-share redemption
     *      trips the tranche's own MUST_REQUEST_NON_ZERO_SHARES inside the simulated frame. Exec is pinned first
     *      so the parity claim is against the live exec error, not a hardcoded expectation
     */
    function test_RevertIf_ZeroAmounts_PreviewsBubbleExactExecErrors() public {
        // Exec side: the zero-asset deposits raise the op-tagged post-op validation error
        vm.prank(ST_PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        seniorTranche.deposit(toTrancheUnits(0), ST_PROVIDER);
        vm.prank(JT_PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        juniorTranche.deposit(toTrancheUnits(0), JT_PROVIDER);
        vm.prank(LT_PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        liquidityTranche.deposit(toTrancheUnits(0), LT_PROVIDER);

        // Preview side: the identical errors bubble verbatim through the simulation seam
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        seniorTranche.previewDeposit(toTrancheUnits(0));
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        juniorTranche.previewDeposit(toTrancheUnits(0));
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        liquidityTranche.previewDeposit(toTrancheUnits(0));

        // Zero-share redemptions: exec and preview raise the identical tranche-level guard
        vm.prank(ST_PROVIDER);
        vm.expectRevert(IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector);
        seniorTranche.redeem(0, ST_PROVIDER, ST_PROVIDER);
        vm.expectRevert(IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector);
        seniorTranche.previewRedeem(0);
        vm.expectRevert(IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector);
        juniorTranche.previewRedeem(0);
        vm.expectRevert(IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector);
        liquidityTranche.previewRedeem(0);
    }

    /**
     * @notice A paused kernel bricks both previews on all three tranches with the same EnforcedPause the
     *         executions raise, so no quote can be produced against a frozen market
     * @dev The simulated frame calls the real whenNotPaused kernel entrypoints, so the pause gate fires inside
     *      the simulation and bubbles verbatim. Exec parity is pinned on the senior pair
     */
    function test_RevertIf_KernelPaused_PreviewsBubbleEnforcedPause() public {
        vm.prank(PAUSER);
        kernel.pause();

        // Exec side: the funded senior deposit clears custody transfer and then dies on the kernel's pause gate
        stJtVault.mintShares(ST_PROVIDER, 1e18);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), 1e18);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.deposit(toTrancheUnits(1e18), ST_PROVIDER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.redeem(1e18, ST_PROVIDER, ST_PROVIDER);
        vm.stopPrank();

        // Preview side: the identical pause revert bubbles from every preview
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.previewDeposit(toTrancheUnits(1e18));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        juniorTranche.previewDeposit(toTrancheUnits(1e18));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        liquidityTranche.previewDeposit(toTrancheUnits(1e18));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.previewRedeem(1e18);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        juniorTranche.previewRedeem(1e18);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        liquidityTranche.previewRedeem(1e18);
    }

    // =============================
    // Simulation gates (spec: a preview-flagged flow can never return, so a preview can never leak state)
    // =============================

    /**
     * @notice Every preview-flagged kernel entrypoint unwinds by reverting with SIMULATION_RESULT even when invoked
     *         outside a simulation frame, on all three tranches and both multi-asset flows
     * @dev The flag is self-enforcing: the flow itself terminates in the result-carrying revert, so no caller can run
     *      a preview whose mutations persist, with or without the tranche's _simulate frame around it
     */
    function test_RevertIf_FlaggedKernelEntrypointInvokedOutsideSimulation() public {
        bytes32 digestBefore = keccak256(abi.encode(accountant.getState(), kernel.getState()));

        vm.prank(address(seniorTranche));
        vm.expectPartialRevert(DispatchLogic.SIMULATION_RESULT.selector);
        kernel.stDeposit(true, toTrancheUnits(1e18));
        vm.prank(address(seniorTranche));
        vm.expectPartialRevert(DispatchLogic.SIMULATION_RESULT.selector);
        kernel.stRedeem(true, 1e18, address(kernel));
        vm.prank(address(juniorTranche));
        vm.expectPartialRevert(DispatchLogic.SIMULATION_RESULT.selector);
        kernel.jtDeposit(true, toTrancheUnits(1e18));
        vm.prank(address(juniorTranche));
        vm.expectPartialRevert(DispatchLogic.SIMULATION_RESULT.selector);
        kernel.jtRedeem(true, 1e18, address(kernel));
        vm.prank(address(liquidityTranche));
        vm.expectPartialRevert(DispatchLogic.SIMULATION_RESULT.selector);
        kernel.ltDeposit(true, toTrancheUnits(1e18));
        vm.prank(address(liquidityTranche));
        vm.expectPartialRevert(DispatchLogic.SIMULATION_RESULT.selector);
        kernel.ltRedeem(true, 1e18, address(kernel));
        vm.prank(address(liquidityTranche));
        vm.expectPartialRevert(DispatchLogic.SIMULATION_RESULT.selector);
        kernel.ltDepositMultiAsset(true, toTrancheUnits(0), 1e6, toTrancheUnits(0));
        vm.prank(address(liquidityTranche));
        vm.expectPartialRevert(DispatchLogic.SIMULATION_RESULT.selector);
        kernel.ltRedeemMultiAsset(true, 1e18, 0, 0, address(kernel));

        assertEq(
            keccak256(abi.encode(accountant.getState(), kernel.getState())), digestBefore, "a flagged flow must leave the committed state untouched"
        );
    }
}

/**
 * @title Test_SimulationSeamPreviewsFixedTerm_Tranches
 * @notice The fixed-term revert parity the seam introduces, including the BEHAVIOR FLIP from the old view
 *         previews: redeem previews now revert DISABLED_IN_FIXED_TERM_STATE exactly like redeem() instead of
 *         returning empty claims, ST and JT deposit previews revert like their deposits, and the LT in-kind
 *         deposit preview keeps quoting because the LT deposit stays enabled in every market state
 * @dev Seeded ST 100e18 / JT 30e18 flat, then a covered -20% drawdown marks coverage utilization at
 *      ceil(104e18 x 0.2 / 4e18) = 5.2e18, above WAD and below the 6.4667e18 liquidation threshold, so the
 *      market enters FIXED_TERM with deposits into loss-bearing tranches and all redemptions locked
 */
contract Test_SimulationSeamPreviewsFixedTerm_Tranches is SimulationSeamPreviewsTestBase {
    function setUp() public override {
        super.setUp();
        _seedFlatMarket(100e18, 30e18, 0);
        applySTPnL(-2000);
        SyncedAccountingState memory state = _sync();
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "the covered drawdown must enter FIXED_TERM");
    }

    /**
     * @notice In FIXED_TERM the senior and junior deposit previews revert DISABLED_IN_FIXED_TERM_STATE exactly
     *         like the executions they simulate
     * @dev Exec is pinned alongside each preview so the parity is against the live exec gate, and the funded
     *      senior attempt proves the gate fires in the kernel, not on custody
     */
    function test_RevertIf_FixedTerm_SeniorAndJuniorPreviewDepositRevertLikeExec() public {
        stJtVault.mintShares(ST_PROVIDER, 1e18);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), 1e18);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        seniorTranche.deposit(toTrancheUnits(1e18), ST_PROVIDER);
        vm.stopPrank();
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        seniorTranche.previewDeposit(toTrancheUnits(1e18));

        stJtVault.mintShares(JT_PROVIDER, 1e18);
        vm.startPrank(JT_PROVIDER);
        stJtVault.approve(address(juniorTranche), 1e18);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        juniorTranche.deposit(toTrancheUnits(1e18), JT_PROVIDER);
        vm.stopPrank();
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        juniorTranche.previewDeposit(toTrancheUnits(1e18));
    }

    /**
     * @notice In FIXED_TERM the LT in-kind deposit preview still quotes (the in-kind LT deposit only deepens
     *         liquidity and stays enabled in every market state) and execution matches it exactly
     * @dev The drawdown lives entirely on the ST/JT vault rate: the quote-only pool is untouched, so 5e18
     *      quote-backed BPT is worth 5e18 NAV against the 6e18 LT effective NAV over 6e18 shares, minting the
     *      offset-adjusted floor((6e18 + 1e6) x 5e18 / (6e18 + 1)) = 5000000000000833332
     */
    function test_FixedTerm_LiquidityPreviewDepositStillQuotes_ExecParity() public {
        _mintQuoteBackedBPT(LT_PROVIDER, 5e18, 5e6);
        uint256 previewed = liquidityTranche.previewDeposit(toTrancheUnits(5e18));
        assertEq(previewed, 5000000000000833332, "the fixed-term LT quote must price the exact offset-adjusted mint on the untouched pool");
        vm.startPrank(LT_PROVIDER);
        bpt.approve(address(liquidityTranche), 5e18);
        assertEq(liquidityTranche.deposit(toTrancheUnits(5e18), LT_PROVIDER), previewed, "the fixed-term LT deposit must mint exactly the previewed shares");
        vm.stopPrank();
    }

    /**
     * @notice In FIXED_TERM all three redeem previews revert DISABLED_IN_FIXED_TERM_STATE exactly like the
     *         redemptions they simulate, the behavior flip from the old empty-claims previews
     * @dev An empty-claims quote in FIXED_TERM was a lie the seam removes: integrators now see the same gate the
     *      execution raises. Each exec is pinned alongside its preview
     */
    function test_RevertIf_FixedTerm_AllPreviewRedeemsRevertLikeExec() public {
        vm.prank(ST_PROVIDER);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        seniorTranche.redeem(1e18, ST_PROVIDER, ST_PROVIDER);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        seniorTranche.previewRedeem(1e18);

        vm.prank(JT_PROVIDER);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        juniorTranche.redeem(1e18, JT_PROVIDER, JT_PROVIDER);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        juniorTranche.previewRedeem(1e18);

        vm.prank(LT_PROVIDER);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        liquidityTranche.redeem(1e18, LT_PROVIDER, LT_PROVIDER);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        liquidityTranche.previewRedeem(1e18);
    }
}

/**
 * @title TestFuzz_SimulationSeamPreviews_Tranches
 * @notice Fuzzes the seam's two core guarantees together across market sizes, coverage ratios, drawdown and
 *         appreciation states, and operation sizes: every preview equals its same-block execution exactly, and
 *         every preview leaves the full market state byte-identical
 * @dev The PnL band spans -5% to +100%. Appreciation runs sync-free so pending premium and fee mints commit
 *      inside the simulated frame. A covered drawdown beyond dust books JT impermanent loss and the next
 *      sync enters FIXED_TERM regardless of utilization, so the drawdown arm first syncs into FIXED_TERM and then
 *      lets the two-week protection term lapse: every flow reopens and each preview must reconcile the
 *      FIXED_TERM-to-PERPETUAL transition (including the IL erasure) inside its own frame, exactly like exec
 */
contract TestFuzz_SimulationSeamPreviews_Tranches is SimulationSeamPreviewsTestBase {
    using Math for uint256;

    /**
     * Scenario: a seeded market absorbs a fuzzed signed PnL over a fuzzed window without syncing, so every
     * preview simulates against pending reconciliation (mints on gains, coverage transfers on losses). All six
     * flows then run back-to-back, and each preview must match its execution exactly while leaving no trace.
     */
    function testFuzz_AllSixFlows_PreviewMatchesExecAndMutatesNothing(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _pnlSeed,
        uint256 _elapsed,
        uint256 _amountSeedA,
        uint256 _amountSeedB,
        uint256 _amountSeedC,
        uint256 _sharesSeedA,
        uint256 _sharesSeedB,
        uint256 _sharesSeedC
    )
        public
    {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        uint256 jt = bound(_jtSeed, st / 2, 2 * st); // uniform coverage ratios from 2:1 to 1:2
        int256 pnlBps = int256(bound(_pnlSeed, 0, 10_500)) - 500; // signed band -5% to +100%
        uint256 elapsed = bound(_elapsed, 1 hours, 365 days); // accrual window from an hour to a year
        // Extra quote-only depth worth 15% of the senior seed keeps the liquidity gate clear after up to +100%
        // senior appreciation, so the senior-deposit and LT-redemption capacities stay positive on every run
        _seedFlatMarket(st, jt, st.mulDiv(3, 20) / QUOTE_TO_NAV_SCALE + 1);

        applySTPnL(pnlBps);
        if (pnlBps < 0) {
            // A covered loss beyond dust always books JT IL, so the sync must land in FIXED_TERM. Letting
            // the two-week term lapse reopens every flow and leaves the state transition itself pending, so every
            // preview and execution below must reconcile the FIXED_TERM-to-PERPETUAL flip in its own sync
            SyncedAccountingState memory ftState = _sync();
            assertEq(uint8(ftState.marketState), uint8(MarketState.FIXED_TERM), "arrange: the covered drawdown must enter FIXED_TERM");
            _warpAndRefreshFeed(2 weeks + elapsed);
        } else {
            // Deliberately NO sync on the appreciation arm: the pending premium and fee mints must commit inside
            // every simulated frame and every execution below
            _warpAndRefreshFeed(elapsed);
        }
        syncVenuePrices();

        // Flow 1: senior deposit, bounded by the live coverage-and-liquidity capacity. A pending premium
        // reinvestment can mark the post-sync LT below the max's idle-premium assumption, overstating the
        // liquidity-capped capacity, the preview must then revert on the gate exactly like the execution
        {
            uint256 assets = bound(_amountSeedA, 1e12, toUint256(seniorTranche.maxDeposit(ST_PROVIDER))); // dust-to-max sizes
            MarketSnapshot memory before = _snapshotMarket();
            try seniorTranche.previewDeposit(toTrancheUnits(assets)) returns (uint256 previewed) {
                _assertSnapshotUnchanged(before, "senior previewDeposit");
                assertEq(_depositSenior(assets), previewed, "senior deposit must mint exactly the previewed shares");
            } catch (bytes memory err) {
                assertEq(
                    bytes4(err), IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector, "the senior deposit preview may only revert on the liquidity gate"
                );
                _assertSnapshotUnchanged(before, "senior previewDeposit");
                stJtVault.mintShares(ST_PROVIDER, assets);
                vm.startPrank(ST_PROVIDER);
                stJtVault.approve(address(seniorTranche), assets);
                vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
                seniorTranche.deposit(toTrancheUnits(assets), ST_PROVIDER);
                vm.stopPrank();
            }
        }

        // Flow 2: junior deposit, never gated, seed-sized at most
        {
            uint256 assets = bound(_amountSeedB, 1e12, st); // dust-sized up to seed-sized junior deposits
            MarketSnapshot memory before = _snapshotMarket();
            uint256 previewed = juniorTranche.previewDeposit(toTrancheUnits(assets));
            _assertSnapshotUnchanged(before, "junior previewDeposit");
            assertEq(_depositJunior(assets), previewed, "junior deposit must mint exactly the previewed shares");
        }

        // Flow 3: in-kind liquidity deposit of freshly minted quote-backed BPT, never gated
        {
            uint256 quoteLeg = bound(_amountSeedC, 1, st / QUOTE_TO_NAV_SCALE); // 1 quote wei up to the senior seed in depth
            uint256 bptIn = quoteLeg * QUOTE_TO_NAV_SCALE;
            _mintQuoteBackedBPT(LT_PROVIDER, bptIn, quoteLeg);
            MarketSnapshot memory before = _snapshotMarket();
            uint256 previewed = liquidityTranche.previewDeposit(toTrancheUnits(bptIn));
            _assertSnapshotUnchanged(before, "liquidity previewDeposit");
            vm.startPrank(LT_PROVIDER);
            bpt.approve(address(liquidityTranche), bptIn);
            assertEq(liquidityTranche.deposit(toTrancheUnits(bptIn), LT_PROVIDER), previewed, "liquidity deposit must mint exactly the previewed shares");
            vm.stopPrank();
        }

        // Flow 4: senior redemption. The 1e6 share-wei floor keeps the payout above the zero-asset threshold the
        // accountant rejects by design, so every run stays on the parity path
        {
            uint256 shares = bound(_sharesSeedA, 1e6, seniorTranche.maxRedeem(ST_PROVIDER));
            MarketSnapshot memory before = _snapshotMarket();
            AssetClaims memory previewed = seniorTranche.previewRedeem(shares);
            _assertSnapshotUnchanged(before, "senior previewRedeem");
            vm.prank(ST_PROVIDER);
            AssetClaims memory claims = seniorTranche.redeem(shares, ST_PROVIDER, ST_PROVIDER);
            _assertClaimsParity(claims, previewed, "senior redemption");
        }

        // Flow 5: junior redemption, bounded by the live coverage-respecting max
        {
            uint256 shares = bound(_sharesSeedB, 1e6, juniorTranche.maxRedeem(JT_PROVIDER)); // dust floor as in flow 4
            MarketSnapshot memory before = _snapshotMarket();
            AssetClaims memory previewed = juniorTranche.previewRedeem(shares);
            _assertSnapshotUnchanged(before, "junior previewRedeem");
            vm.prank(JT_PROVIDER);
            AssetClaims memory claims = juniorTranche.redeem(shares, JT_PROVIDER, JT_PROVIDER);
            _assertClaimsParity(claims, previewed, "junior redemption");
        }

        // Flow 6: in-kind liquidity redemption, bounded by the live liquidity-respecting max, guarded on the
        // gate like flow 1 since the same reinvestment wedge can overstate the redemption capacity
        {
            uint256 shares = bound(_sharesSeedC, 1e6, liquidityTranche.maxRedeem(LT_PROVIDER)); // dust floor as in flow 4
            MarketSnapshot memory before = _snapshotMarket();
            try liquidityTranche.previewRedeem(shares) returns (AssetClaims memory previewed) {
                _assertSnapshotUnchanged(before, "liquidity previewRedeem");
                vm.prank(LT_PROVIDER);
                AssetClaims memory claims = liquidityTranche.redeem(shares, LT_PROVIDER, LT_PROVIDER);
                _assertClaimsParity(claims, previewed, "liquidity redemption");
            } catch (bytes memory err) {
                assertEq(
                    bytes4(err), IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector, "the liquidity redemption preview may only revert on the liquidity gate"
                );
                _assertSnapshotUnchanged(before, "liquidity previewRedeem");
                vm.prank(LT_PROVIDER);
                vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
                liquidityTranche.redeem(shares, LT_PROVIDER, LT_PROVIDER);
            }
        }
    }

    /**
     * Scenario: a fuzzed covered drawdown breaches the liquidation threshold (which forces the market PERPETUAL),
     * arming the ST self-liquidation bonus. The senior redemption preview must then match the bonus-boosted
     * execution exactly on every claim leg for any redeemable slice, while leaving the market state untouched.
     * The drawdown band [-23%, -20.8%] at the 30% junior ratio always breaches the 6.4667 threshold without
     * exhausting the junior buffer (exhaustion sits at -23.077%), mirroring the dedicated bonus suite's band.
     */
    function testFuzz_SeniorRedeemPreviewParity_LiquidationBonusRegime(uint256 _stSeed, uint256 _drawdownBps, uint256 _sharesSeed) public {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        uint256 drawdownBps = bound(_drawdownBps, 2080, 2300); // always past the liquidation threshold, buffer never exhausted
        _seedFlatMarket(st, st * 3 / 10, 0);

        applySTPnL(-int256(drawdownBps));
        SyncedAccountingState memory state = _sync();
        assertGe(state.coverageUtilizationWAD, state.coverageLiquidationUtilizationWAD, "the drawdown must breach the liquidation coverage threshold");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "a liquidation breach forces the market PERPETUAL so redemptions stay open");

        // The loss is fully covered so one senior share claims exactly one NAV wei of base value, and the bonus
        // rides on top: the previewed NAV must never quote below the base slice
        uint256 shares = bound(_sharesSeed, 1e6, st); // dust-to-full-exit slices
        MarketSnapshot memory before = _snapshotMarket();
        AssetClaims memory previewed = seniorTranche.previewRedeem(shares);
        _assertSnapshotUnchanged(before, "bonus-regime previewRedeem");
        assertGe(toUint256(previewed.nav), shares, "the bonus-regime quote must carry at least the base pro-rata slice");

        vm.prank(ST_PROVIDER);
        AssetClaims memory claims = seniorTranche.redeem(shares, ST_PROVIDER, ST_PROVIDER);
        _assertClaimsParity(claims, previewed, "bonus-boosted senior redemption");
    }
}
