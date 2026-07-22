// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoBlacklist } from "../../../src/auth/RoycoBlacklist.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { AssetClaims, MarketState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toUint256 } from "../../../src/libraries/Units.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { MockBalancerVault } from "../../mocks/MockBalancerVault.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { MarketParamsConfig, defaultParams, zeroLiquidityParams } from "../../utils/MarketParams.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_MultiAssetMaxRedeemBoundary
 * @notice The multi-asset redemption maximum against the liquidity requirement it is bounded by: a multi-asset
 *         exit redeems its senior tranche share legs in-flow, shrinking the requirement alongside the withdrawal,
 *         so its bound must weakly dominate the in-kind bound, coincide with it when the removal carries no
 *         senior-share value, be a TRUE maximum at the gate (the reported size executes, a hair more reverts),
 *         and mirror the in-kind max's waiver, fixed-term, blacklist, and pause semantics
 * @dev Also pins the execute-and-revert multi-asset previews: preview outputs must equal execution's token
 *      deltas exactly, previews must leave every market ledger byte-identical, genuine venue failures must
 *      bubble out of a preview unchanged, and previews must compose inside a state-mutating transaction,
 *      a context the Vault's own query mode can never serve
 */
contract Test_MultiAssetMaxRedeemBoundary is DayMarketTestBase {
    /// @dev One whole quote token in its native decimals (this market's quote asset uses 6 decimals, so 1e6)
    uint256 internal QUOTE_UNIT;

    /**
     * @dev Seeds a market whose liquidity requirement genuinely binds the LT bounds: 30,000 junior vault shares
     *      (coverage first), 100,000 senior vault shares, then real two-leg pool depth of 2,000 senior shares
     *      against 8,000 quote tokens minted as 10,000e18 pool tokens so NAV-per-BPT stays exactly 1.0, the
     *      committed requirement (~5% of ~102,000e18 senior effective NAV) leaves in-kind headroom of roughly
     *      two thirds of the LT supply, so the gate, not the balance, binds both maxima
     */
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        QUOTE_UNIT = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(100_000e18, 30_000e18);
        _seedLT(10_000e18, 2000e18, 8000 * QUOTE_UNIT);
        _sync();
    }

    // =============================
    // Fixture helpers
    // =============================

    /**
     * @dev Byte-exact digest of every ledger a multi-asset flow can touch: the committed accounting
     *      checkpoint, the kernel's ownership ledgers (including ltOwnedSeniorTrancheShares), all three
     *      share supplies, the kernel's and the actor's token balances, and the pool's own reserves and supply
     */
    function _marketDigest(address _actor) internal view returns (bytes32) {
        uint256[2] memory poolBalances = balancerVault.getPoolBalances(address(bpt));
        return keccak256(
            abi.encode(
                accountant.getState(),
                kernel.getState(),
                seniorTranche.totalSupply(),
                juniorTranche.totalSupply(),
                liquidityTranche.totalSupply(),
                stJtVault.balanceOf(address(kernel)),
                bpt.balanceOf(address(kernel)),
                seniorTranche.balanceOf(address(kernel)),
                quoteToken.balanceOf(address(kernel)),
                poolBalances,
                bpt.totalSupply(),
                seniorTranche.balanceOf(address(balancerVault)),
                quoteToken.balanceOf(address(balancerVault)),
                stJtVault.balanceOf(_actor),
                quoteToken.balanceOf(_actor),
                bpt.balanceOf(_actor),
                seniorTranche.balanceOf(_actor),
                liquidityTranche.balanceOf(_actor)
            )
        );
    }

    /// @dev The committed liquidity utilization, read from the accountant's last checkpoint
    function _liquidityUtilization() internal view returns (uint256 utilizationWAD) {
        IRoycoDayAccountant.RoycoDayAccountantState memory state = accountant.getState();
        return RoycoTestMath.computeLiquidityUtilization(toUint256(state.lastSTEffectiveNAV), uint256(state.minLiquidityWAD), toUint256(state.lastLTRawNAV));
    }

    /**
     * @dev Accumulates idle liquidity premium senior shares in the kernel: arms the venue's punitive
     *      slippage so the sync's reinvest gate fails, then realizes a 2% senior gain over a day so the
     *      fee and liquidity premium share mint produces senior shares that cannot deploy and must sit
     *      in ltOwnedSeniorTrancheShares
     */
    function _accumulateIdleLiquidityPremiumSeniorShares() internal returns (uint256 idleShares) {
        setVenueSlippageMode(true);
        _warpAndRefreshFeed(1 days);
        applySTPnL(200);
        _sync();
        idleShares = kernel.getState().ltOwnedSeniorTrancheShares;
        require(idleShares != 0, "setup: expected the liquidity premium to sit as idle senior shares");
    }

    // =============================
    // The maximum's algebra: boundary, wedge, dominance, equality
    // =============================

    /// @notice The reported maximum is a true maximum at the liquidity gate: it executes, and a hair more reverts
    function test_RedeemMultiAsset_MaxRedeemMultiAssetBoundary_ExactlyRedeemable() public {
        uint256 maxShares = liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER);
        assertGt(maxShares, 0, "the fixture must leave multi-asset redemption capacity");
        assertLt(maxShares, liquidityTranche.balanceOf(LT_PROVIDER), "the gate, not the balance, must bind the maximum");

        // Breach first, the reverted attempt leaves no trace (pinned by the atomicity suite). The slack covers
        // the accountant's one-NAV-wei dust tolerance plus the flow's quote and share quantization floors
        uint256 breachShares =
            maxShares + Math.mulDiv(2e12 + 1, liquidityTranche.totalSupply(), toUint256(accountant.getState().lastLTRawNAV), Math.Rounding.Ceil) + 2;
        vm.prank(LT_PROVIDER);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        liquidityTranche.redeemMultiAsset(breachShares, 0, 0, LT_PROVIDER, LT_PROVIDER);

        // The advertised maximum itself must clear the gate and leave the market at or below full utilization
        vm.prank(LT_PROVIDER);
        liquidityTranche.redeemMultiAsset(maxShares, 0, 0, LT_PROVIDER, LT_PROVIDER);
        _sync();
        assertLe(_liquidityUtilization(), WAD, "the executed maximum must respect the liquidity requirement");
    }

    /// @notice There are share amounts the in-kind path must reject but the multi-asset path must accept: the
    ///         multi-asset exit redeems its senior-share legs in-flow, shrinking the requirement it is gated by
    function test_RedeemMultiAsset_Wedge_InKindRevertsWhereMultiAssetSucceeds() public {
        uint256 wedgeShares = liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER);
        assertGt(wedgeShares, liquidityTranche.maxRedeem(LT_PROVIDER) + 1e18, "the wedge window between the two bounds must be real");

        // In-kind hands the pool tokens away without touching the senior tranche, so only the requirement's
        // supply side shrinks, at the wedge size it must breach the gate
        vm.prank(LT_PROVIDER);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        liquidityTranche.redeem(wedgeShares, LT_PROVIDER, LT_PROVIDER);

        // The same size clears multi-asset because the requirement shrinks alongside the withdrawal
        vm.prank(LT_PROVIDER);
        liquidityTranche.redeemMultiAsset(wedgeShares, 0, 0, LT_PROVIDER, LT_PROVIDER);
        _sync();
        assertLe(_liquidityUtilization(), WAD, "the wedge execution must respect the liquidity requirement");
    }

    /// @notice The multi-asset bound weakly dominates the in-kind bound in every state, strictly once the
    ///         idle liquidity premium pile adds senior-share relief
    function test_MaxRedeemMultiAsset_WeaklyDominatesInKindAcrossStates() public {
        assertGe(liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER), liquidityTranche.maxRedeem(LT_PROVIDER), "dominance must hold at the seeded state");

        // A staged un-reinvested premium adds relief on top of the pool's senior leg: dominance turns strict
        _accumulateIdleLiquidityPremiumSeniorShares();
        assertGt(
            liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER),
            liquidityTranche.maxRedeem(LT_PROVIDER),
            "a staged premium pile must widen the multi-asset bound strictly past the in-kind bound"
        );

        // A liquidity drawdown moves both bounds but must never invert them
        applyLTPnL(-3000);
        _sync();
        assertGt(liquidityTranche.maxRedeem(LT_PROVIDER), 0, "the drawdown fixture must keep in-kind capacity open");
        assertGe(liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER), liquidityTranche.maxRedeem(LT_PROVIDER), "dominance must hold through a drawdown");
    }

    /// @notice With no senior-share value in the removal and no idle premium, the two maxima coincide exactly:
    ///         the dominance is an equality at zero relief and both bounds share the same zero point
    function test_MaxRedeemMultiAsset_EqualsInKindWithoutSeniorLegOrPremium() public {
        // Redeploy with quote-only pool legs so a proportional removal returns no senior shares
        _deployMarket(cellA(), defaultParams());
        _seedMarket(100_000e18, 30_000e18);
        _seedLT(10_000e18, 0, 10_000 * QUOTE_UNIT);
        _sync();

        uint256 multiAssetMax = liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER);
        uint256 inKindMax = liquidityTranche.maxRedeem(LT_PROVIDER);
        assertEq(multiAssetMax, inKindMax, "zero relief must collapse the multi-asset bound onto the in-kind bound");
        assertGt(multiAssetMax, 0, "the equality must be tested with live capacity");
        assertLt(multiAssetMax, liquidityTranche.balanceOf(LT_PROVIDER), "the equality must be on the gate branch, not the balance clamp");
    }

    /// @notice With every circulating senior share inside the pool, the multi-asset exit is NEARLY full but never
    ///         total: the venue's minimum-supply reserve (dead pool tokens minted to the zero address at pool
    ///         initialization) permanently strands a pro-rata sliver of the senior leg, so a whole-balance exit
    ///         leaves live senior backing against zero market-making depth and must violate the liquidity
    ///         requirement, while the reported maximum, a hair under the balance, executes
    function test_MaxRedeemMultiAsset_AllSeniorSharesInPool_NearFullExitExecutesWholeBalanceReverts() public {
        // Redeploy with no outside senior seed: the only senior shares ever minted are the pool leg's
        _deployMarket(cellA(), defaultParams());
        _seedMarket(0, 30_000e18);
        _seedLT(10_000e18, 2000e18, 8000 * QUOTE_UNIT);
        // Sweep the acquisition cushion so the pool holds every circulating senior share
        uint256 residue = seniorTranche.balanceOf(address(this));
        if (residue != 0) seniorTranche.redeem(residue, address(this), address(this));
        _sync();
        assertEq(seniorTranche.balanceOf(address(balancerVault)), seniorTranche.totalSupply(), "setup: every circulating senior share must sit in the pool");
        assertGt(seniorTranche.totalSupply(), 0, "setup: the senior supply must be live");

        // In-kind hands the pool away with the senior supply intact, so its bound sits far below the balance
        uint256 balance = liquidityTranche.balanceOf(LT_PROVIDER);
        assertLt(liquidityTranche.maxRedeem(LT_PROVIDER), balance, "the in-kind bound must never approach the full exit");

        // The multi-asset bound closes to within a millionth of the balance but must stop strictly short of it:
        // the stranded senior sliver keeps the post-exit requirement alive with no depth left to satisfy it
        uint256 maxShares = liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER);
        assertLt(maxShares, balance, "the stranded senior sliver must keep the bound strictly under the balance");
        assertGe(maxShares, balance - balance / 1e6, "the bound must close to within a millionth of the full balance");

        // The whole balance breaches: the removal cannot reach the reserve's senior sliver, so senior backing
        // survives the exit while the market-making depth does not
        vm.prank(LT_PROVIDER);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        liquidityTranche.redeemMultiAsset(balance, 0, 0, LT_PROVIDER, LT_PROVIDER);

        // The reported maximum itself executes, leaving the market at or below full utilization
        vm.prank(LT_PROVIDER);
        liquidityTranche.redeemMultiAsset(maxShares, 0, 0, LT_PROVIDER, LT_PROVIDER);
        _sync();
        assertLe(_liquidityUtilization(), WAD, "the executed maximum must respect the liquidity requirement");
        assertGt(seniorTranche.balanceOf(address(balancerVault)), 0, "the venue's minimum-supply reserve must still hold its senior sliver");
    }

    // =============================
    // Waivers and gates: the same semantics as the in-kind max
    // =============================

    /// @notice A zero minimum-liquidity market waives the requirement entirely: both maxima report the full balance and the full exit executes
    function test_MaxRedeemMultiAsset_ZeroMinLiquidityMarket_ReportsFullBalance() public {
        _deployMarket(cellA(), zeroLiquidityParams());
        _seedMarket(100_000e18, 30_000e18);
        _seedLT(10_000e18, 2000e18, 8000 * QUOTE_UNIT);
        _sync();

        uint256 balance = liquidityTranche.balanceOf(LT_PROVIDER);
        assertEq(liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER), balance, "a waived requirement must report the full balance");
        assertEq(liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER), liquidityTranche.maxRedeem(LT_PROVIDER), "both maxima must agree under the waiver");

        vm.prank(LT_PROVIDER);
        liquidityTranche.redeemMultiAsset(balance, 0, 0, LT_PROVIDER, LT_PROVIDER);
        assertEq(liquidityTranche.balanceOf(LT_PROVIDER), 0, "the full exit must execute under the waiver");
    }

    /// @notice Past the coverage liquidation threshold the liquidity requirement still holds: the multi-asset
    ///         maximum reports a bounded surplus below the full balance (a multi-asset exit relaxes the floor by
    ///         unwinding senior depth, so it dominates the in-kind maximum but never waives the gate), a full
    ///         exit reverts, and redeeming exactly the maximum leaves the liquidity floor satisfied
    function test_MaxRedeemMultiAsset_CoverageLiquidationBreach_EnforcesLiquidityGate() public {
        // Crash the shared senior/junior rate 60%: junior absorbs losses until exhausted, so coverage
        // utilization reads past the liquidation threshold and the market forces perpetual
        applySTPnL(-6000);
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        uint256 coverageUtilizationWAD =
            RoycoTestMath.computeCoverageUtilization(toUint256(a.lastSTRawNAV), toUint256(a.lastJTRawNAV), a.minCoverageWAD, toUint256(a.lastJTEffectiveNAV));
        assertGe(coverageUtilizationWAD, a.coverageLiquidationUtilizationWAD, "setup: expected liquidation coverage to read breached");

        // The breach no longer waives the liquidity gate: the multi-asset maximum is a bounded surplus below the
        // full balance, and it still dominates the in-kind maximum because a multi-asset exit relaxes the floor
        uint256 balance = liquidityTranche.balanceOf(LT_PROVIDER);
        uint256 maxMulti = liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER);
        assertGt(maxMulti, 0, "a multi-asset exit that relaxes the floor must still be possible");
        assertLt(maxMulti, balance, "the breach must not waive the requirement: the maximum stays below the full balance");
        assertGe(maxMulti, liquidityTranche.maxRedeem(LT_PROVIDER), "the multi-asset maximum must dominate the in-kind maximum");

        // A full exit past the bounded maximum reverts on the enforced liquidity gate
        vm.prank(LT_PROVIDER);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        liquidityTranche.redeemMultiAsset(balance, 0, 0, LT_PROVIDER, LT_PROVIDER);

        // Redeeming exactly the advertised maximum succeeds and leaves the liquidity floor at or below 100%
        vm.prank(LT_PROVIDER);
        liquidityTranche.redeemMultiAsset(maxMulti, 0, 0, LT_PROVIDER, LT_PROVIDER);
        _sync();
        assertLe(_liquidityUtilization(), WAD, "redeeming exactly the maximum must leave the liquidity floor satisfied");
    }

    /// @notice A fixed-term market disables LT redemptions: the maximum reports zero and the flow reverts
    function test_MaxRedeemMultiAsset_FixedTerm_ReportsZeroAndRedeemReverts() public {
        applySTPnL(-2000);
        assertEq(uint8(_sync().marketState), uint8(MarketState.FIXED_TERM), "setup: expected the covered loss to enter a fixed term");

        assertEq(liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER), 0, "a fixed-term market must zero the multi-asset maximum");
        assertEq(liquidityTranche.maxRedeem(LT_PROVIDER), 0, "the in-kind maximum must mirror the zero");

        vm.prank(LT_PROVIDER);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        liquidityTranche.redeemMultiAsset(1e18, 0, 0, LT_PROVIDER, LT_PROVIDER);
    }

    /// @notice A blacklisted owner and a paused kernel each zero the advertised maximum, and clearing the condition restores it
    function test_MaxRedeemMultiAsset_BlacklistAndPause_ReportZeroLikeInKind() public {
        RoycoBlacklist roycoBlacklist = RoycoBlacklist(
            address(
                new ERC1967Proxy(
                    address(new RoycoBlacklist()), abi.encodeCall(RoycoBlacklist.initialize, (address(accessManager), address(0), new address[](0)))
                )
            )
        );
        vm.prank(MARKET_OPS_ADMIN);
        kernel.setRoycoBlacklist(address(roycoBlacklist));

        address[] memory flagged = new address[](1);
        flagged[0] = LT_PROVIDER;
        roycoBlacklist.blacklistAccounts(flagged);
        assertEq(liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER), 0, "a blacklisted owner must read a zero multi-asset maximum");
        assertEq(liquidityTranche.maxRedeem(LT_PROVIDER), 0, "the in-kind maximum must mirror the zero");
        roycoBlacklist.unblacklistAccounts(flagged);
        assertGt(liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER), 0, "clearing the blacklist must restore the maximum");

        vm.prank(PAUSER);
        kernel.pause();
        assertEq(liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER), 0, "a paused kernel must read a zero multi-asset maximum");
        assertEq(liquidityTranche.maxRedeem(LT_PROVIDER), 0, "the in-kind maximum must mirror the zero");
        vm.prank(UNPAUSER);
        kernel.unpause();
        assertGe(liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER), liquidityTranche.maxRedeem(LT_PROVIDER), "unpausing must restore the dominant maximum");
    }

    /// @notice A market with no liquidity tranche deposits reports a zero maximum instead of reverting on the empty venue preview
    function test_MaxRedeemMultiAsset_EmptyLiquidityTranche_ReportsZero() public {
        // Redeploy without seeding: the kernel holds no LT assets, so the bound must short-circuit the venue preview
        _deployMarket(cellA(), defaultParams());

        assertEq(liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER), 0, "an empty liquidity tranche must report a zero multi-asset maximum");
        (NAV_UNIT claimOnLTNAV, NAV_UNIT ltMaxWithdrawableNAV,) = kernel.ltMaxWithdrawableMultiAsset(LT_PROVIDER);
        assertEq(toUint256(claimOnLTNAV), 0, "an empty liquidity tranche must carry no LT claims");
        assertEq(toUint256(ltMaxWithdrawableNAV), 0, "an empty liquidity tranche must report zero withdrawable NAV");
    }

    /// @notice The boundary holds without the dust tolerance: the bound's safety must rest on its own floor
    ///         rounding, not on the accountant's absorber
    function test_RedeemMultiAsset_MaxBoundary_HoldsWithZeroDustTolerance() public {
        MarketParamsConfig memory params = defaultParams();
        params.stNAVDustTolerance = 0;
        _deployMarket(cellA(), params);
        _seedMarket(100_000e18, 30_000e18);
        _seedLT(10_000e18, 2000e18, 8000 * QUOTE_UNIT);
        _sync();

        uint256 maxShares = liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER);
        assertGt(maxShares, 0, "the zero-dust fixture must leave multi-asset redemption capacity");
        assertLt(maxShares, liquidityTranche.balanceOf(LT_PROVIDER), "the gate, not the balance, must bind the maximum");

        vm.prank(LT_PROVIDER);
        liquidityTranche.redeemMultiAsset(maxShares, 0, 0, LT_PROVIDER, LT_PROVIDER);
        _sync();
        assertLe(_liquidityUtilization(), WAD, "the executed maximum must respect the liquidity requirement without the dust absorber");
    }

    /// @notice The boundary holds in a senior-share-skewed pool under a conservative mark: with the oracle pinned
    ///         below fair value the full holding's senior-share redemption value exceeds the LT raw NAV outright,
    ///         and the reported maximum must still execute
    /// @dev Only the success direction is asserted: a MANUAL-mode mark is static through the removal, so the
    ///      post-removal state reads easier than the linear model and a breach probe would not be meaningful
    function test_RedeemMultiAsset_MaxBoundary_HoldsInSeniorSkewedPoolWithConservativeMark() public {
        // A senior-share-heavy pool: 8,000e18 of senior legs against 2,000 quote
        _deployMarket(cellA(), defaultParams());
        _seedMarket(100_000e18, 30_000e18);
        _seedLT(10_000e18, 8000e18, 2000 * QUOTE_UNIT);
        _sync();

        // Pin the mark at 45% of fair value: the conservative mark understates the senior leg
        bptOracle.setTVL((bptOracle.computeTVL() * 45) / 100);
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);
        _sync();

        // The full holding's senior-share redemption value must exceed the LT raw NAV (r > 1)
        uint256 stSharesInPool = seniorTranche.balanceOf(address(balancerVault));
        uint256 stSharesInFullRemoval = (stSharesInPool * bpt.balanceOf(address(kernel))) / bpt.totalSupply();
        uint256 seniorShareRedemptionNAV = (stSharesInFullRemoval * kernel.getRate()) / 1e18;
        assertGt(
            seniorShareRedemptionNAV,
            toUint256(accountant.getState().lastLTRawNAV),
            "setup: the conservative mark must push the senior-share redemption value past the LT raw NAV"
        );

        uint256 maxShares = liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER);
        assertGt(maxShares, liquidityTranche.maxRedeem(LT_PROVIDER), "the skewed state must widen the multi-asset bound past the in-kind bound");

        vm.prank(LT_PROVIDER);
        liquidityTranche.redeemMultiAsset(maxShares, 0, 0, LT_PROVIDER, LT_PROVIDER);
        _sync();
        assertLe(_liquidityUtilization(), WAD, "the executed maximum must respect the liquidity requirement under the conservative mark");
    }

    /// @notice The wiped-mark corner: with the LT mark at zero, an un-reinvested premium pile, and the liquidity
    ///         requirement waived, a multi-asset redemption still executes through the accountant's zero-delta
    ///         carve-out (senior redemption NAV flows in-flow) while the in-kind path cannot, and both maxima
    ///         conservatively report zero rather than advertising the carve-out
    function test_MaxRedeemMultiAsset_WipedMarkWithPremium_ConservativeZeroWhileCarveOutExecutes() public {
        // Waive only the liquidity requirement: the zero-liquidity preset also zeroes the LT yield share,
        // which would starve the premium pile this corner needs
        MarketParamsConfig memory params = defaultParams();
        params.minLiquidityWAD = 0;
        _deployMarket(cellA(), params);
        _seedMarket(100_000e18, 30_000e18);
        _seedLT(10_000e18, 2000e18, 8000 * QUOTE_UNIT);
        _sync();
        _accumulateIdleLiquidityPremiumSeniorShares();

        // Wipe the LT mark to exactly zero while the premium pile persists
        bptOracle.setTVL(0);
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);
        _sync();
        require(kernel.getState().ltOwnedSeniorTrancheShares != 0, "setup: expected the premium pile to persist through the wipe");

        // Both maxima report the conservative zero: the tranche has no claims at the wiped mark
        assertEq(liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER), 0, "the wiped mark must zero the multi-asset maximum");
        assertEq(liquidityTranche.maxRedeem(LT_PROVIDER), 0, "the in-kind maximum must mirror the zero");

        // The multi-asset flow still executes through the zero-delta carve-out, redeeming the premium slice in-flow
        uint256 sharesToRedeem = liquidityTranche.balanceOf(LT_PROVIDER) / 4;
        uint256 vaultSharesBefore = stJtVault.balanceOf(LT_PROVIDER);
        vm.prank(LT_PROVIDER);
        liquidityTranche.redeemMultiAsset(sharesToRedeem, 0, 0, LT_PROVIDER, LT_PROVIDER);
        assertGt(stJtVault.balanceOf(LT_PROVIDER) - vaultSharesBefore, 0, "the premium slice must pay out through the carve-out");

        // The in-kind path delivers the same premium: handing the idle senior shares over in kind moves no raw NAV
        // (they stay in the senior supply), so the LT_REDEEM shape check commits it as a NAV-neutral redemption
        uint256 idleBeforeInKind = kernel.getState().ltOwnedSeniorTrancheShares;
        uint256 supplyBeforeInKind = liquidityTranche.totalSupply();
        uint256 seniorBeforeInKind = seniorTranche.balanceOf(LT_PROVIDER);
        uint256 expectedIdleSlice = Math.mulDiv(1e18, idleBeforeInKind, supplyBeforeInKind, Math.Rounding.Floor);
        assertGt(expectedIdleSlice, 0, "the in-kind idle slice must be nonzero");

        vm.prank(LT_PROVIDER);
        AssetClaims memory inKindClaims = liquidityTranche.redeem(1e18, LT_PROVIDER, LT_PROVIDER);

        // Exactly the pro-rata idle senior shares are handed over in kind, the wiped BPT leg pays nothing, and the
        // kernel's idle pile drops by exactly that slice
        assertEq(inKindClaims.stShares, expectedIdleSlice, "the in-kind redeem must pay exactly the pro-rata idle senior share slice");
        assertEq(toUint256(inKindClaims.ltAssets), 0, "the wiped BPT leg must pay nothing in kind");
        assertEq(seniorTranche.balanceOf(LT_PROVIDER) - seniorBeforeInKind, expectedIdleSlice, "the redeemer must receive exactly its idle senior share slice");
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, idleBeforeInKind - expectedIdleSlice, "the kernel's idle pile must drop by exactly the redeemed slice");
        assertEq(bpt.balanceOf(LT_PROVIDER), 0, "no BPT can be delivered against a zero pool-depth mark");
    }

    // =============================
    // The execute-and-revert previews
    // =============================

    /// @notice Preview equals execution at the token layer: the receiver's actual quote and vault-share deltas
    ///         from a multi-asset redemption match the preview's outputs exactly, idle premium leg included
    function test_LTRedeemMultiAsset_ConstituentsMatchPreview_ByTokenBalanceDeltas() public {
        // Stage an idle premium and leave the punitive slippage armed: the pro-rata removal ignores the add
        // haircut, and the armed gate keeps the pile from reinvesting during the flow's own pre-op sync
        _accumulateIdleLiquidityPremiumSeniorShares();
        uint256 shares = liquidityTranche.balanceOf(LT_PROVIDER) / 4;

        vm.startPrank(LT_PROVIDER);
        (AssetClaims memory previewClaims, uint256 previewQuote) = liquidityTranche.previewRedeemMultiAsset(shares);
        uint256 quoteBefore = quoteToken.balanceOf(LT_PROVIDER);
        uint256 vaultSharesBefore = stJtVault.balanceOf(LT_PROVIDER);
        (AssetClaims memory claims, uint256 quoteOut) = liquidityTranche.redeemMultiAsset(shares, 0, 0, LT_PROVIDER, LT_PROVIDER);
        vm.stopPrank();

        assertEq(quoteToken.balanceOf(LT_PROVIDER) - quoteBefore, previewQuote, "the quote leg must land exactly as previewed");
        // The ST and JT assets are the same shared vault share in this kernel family, so the two legs land as one delta
        assertEq(
            stJtVault.balanceOf(LT_PROVIDER) - vaultSharesBefore,
            toUint256(previewClaims.stAssets) + toUint256(previewClaims.jtAssets),
            "the senior unwind's vault shares must land exactly as previewed"
        );
        assertEq(quoteOut, previewQuote, "the returned quote must match the preview");
        assertEq(keccak256(abi.encode(claims)), keccak256(abi.encode(previewClaims)), "the returned claims must match the preview leg for leg");
    }

    /// @notice Preview equals execution on the deposit side: the venue mints exactly the previewed pool tokens
    ///         and the tranche mints exactly the previewed shares
    function test_LTDepositMultiAsset_MintedBPTMatchesPreviewAdd_ByBalanceDelta() public {
        address actor = LT_PROVIDER;
        uint256 stAssets = 100e18;
        uint256 quoteAssets = 100 * QUOTE_UNIT;
        stJtVault.mintShares(actor, stAssets);
        quoteToken.mint(actor, quoteAssets);
        vm.startPrank(actor);
        stJtVault.approve(address(liquidityTranche), stAssets);
        quoteToken.approve(address(liquidityTranche), quoteAssets);
        vm.stopPrank();

        // The preview surfaces the venue's pool-token mint directly as its second return
        (uint256 previewShares, uint256 previewLtAssetsOut) = liquidityTranche.previewDepositMultiAsset(stAssets, quoteAssets);
        uint256 kernelBptBefore = bpt.balanceOf(address(kernel));

        vm.prank(actor);
        (uint256 minted, uint256 ltAssetsOut) = liquidityTranche.depositMultiAsset(stAssets, quoteAssets, 0, actor);

        assertEq(bpt.balanceOf(address(kernel)) - kernelBptBefore, previewLtAssetsOut, "the venue must mint exactly the previewed pool tokens");
        assertEq(minted, previewShares, "the tranche must mint exactly the previewed shares");
        assertEq(ltAssetsOut, previewLtAssetsOut, "the executed deposit must report exactly the previewed pool tokens");
    }

    /// @notice Every preview leaves every market ledger byte-identical: the result-carrying revert must unwind
    ///         the venue's transient accounting completely, moving no tokens, pool tokens, shares, or committed state
    function test_MultiAssetPreviews_AreNetStateNeutral() public {
        // Stage an idle premium so the previewed removal exercises both LT legs
        _accumulateIdleLiquidityPremiumSeniorShares();

        bytes32 digestBefore = _marketDigest(LT_PROVIDER);
        liquidityTranche.previewRedeemMultiAsset(liquidityTranche.balanceOf(LT_PROVIDER) / 3);
        liquidityTranche.previewDepositMultiAsset(50e18, 50 * QUOTE_UNIT);
        liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER);
        kernel.ltMaxWithdrawableMultiAsset(LT_PROVIDER);
        assertEq(_marketDigest(LT_PROVIDER), digestBefore, "a preview left a trace on the market");
    }

    /// @notice The previews simulate through the unlocked Vault and never touch its query mode, whose static-call
    ///         gate would revert every on-chain caller
    function test_MultiAssetPreviews_RouteThroughUnlockedVaultNeverQueryMode() public {
        vm.expectCall(address(balancerVault), abi.encodeWithSelector(MockBalancerVault.quote.selector), 0);
        vm.expectCall(address(balancerVault), abi.encodeWithSelector(MockBalancerVault.unlock.selector), 2);
        liquidityTranche.previewRedeemMultiAsset(liquidityTranche.balanceOf(LT_PROVIDER) / 4);
        liquidityTranche.previewDepositMultiAsset(10e18, 10 * QUOTE_UNIT);
    }

    /// @notice Zero and dust share previews return zero outputs without reverting: a slice too small to carry
    ///         any LT assets never reaches the venue
    function test_MultiAssetPreviews_ZeroAndDustShares_ReturnZeroOutputsWithoutReverting() public {
        (AssetClaims memory zeroClaims, uint256 zeroQuote) = liquidityTranche.previewRedeemMultiAsset(0);
        assertEq(zeroQuote, 0, "a zero-share preview must carry no quote leg");
        assertEq(toUint256(zeroClaims.nav), 0, "a zero-share preview must carry no claim value");

        // One share-wei of a roughly fifteen-thousand-NAV pool floors every constituent leg to zero
        (AssetClaims memory dustClaims, uint256 dustQuote) = liquidityTranche.previewRedeemMultiAsset(1);
        assertEq(dustQuote, 0, "a dust preview must floor the quote leg to zero");
        assertEq(toUint256(dustClaims.nav), 0, "a dust preview must floor the claim value to zero");
    }

    /// @notice A dust ST leg that floors to zero senior shares reverts the multi-asset preview and the execution identically
    /// @dev With senior shares appreciated past one NAV each, a one-wei ST leg values below a whole senior share and
    ///      floors to zero. The execution path mints that zero senior share and reverts MUST_MINT_NON_ZERO_SHARES, and
    ///      the preview runs that same flow, so the doomed deposit's revert bubbles from the preview unchanged
    function test_RevertIf_LTDepositMultiAsset_DustSTLegFloorsToZeroSeniorShares_PreviewAndExecution() public {
        // Appreciate the senior leg 20% so each senior share is worth more than one NAV: a one-wei ST leg now floors
        // to zero senior shares in both the preview and the execution
        applySTPnL(2000);
        _sync();

        uint256 dustSTLeg = 1;
        uint256 quoteAssets = 100 * QUOTE_UNIT;

        // The preview bubbles the zero-share senior mint's revert, quoting nothing for a deposit that deterministically reverts
        vm.expectRevert(IRoycoVaultTranche.MUST_MINT_NON_ZERO_SHARES.selector);
        liquidityTranche.previewDepositMultiAsset(dustSTLeg, quoteAssets);

        // The execution reverts on the same zero-share senior mint
        stJtVault.mintShares(LT_PROVIDER, dustSTLeg);
        quoteToken.mint(LT_PROVIDER, quoteAssets);
        vm.startPrank(LT_PROVIDER);
        stJtVault.approve(address(liquidityTranche), dustSTLeg);
        quoteToken.approve(address(liquidityTranche), quoteAssets);
        vm.expectRevert(IRoycoVaultTranche.MUST_MINT_NON_ZERO_SHARES.selector);
        liquidityTranche.depositMultiAsset(dustSTLeg, quoteAssets, 0, LT_PROVIDER);
        vm.stopPrank();

        // A pure quote-only deposit in the same state is untouched by the dust guard: it previews a positive share
        // amount and executes, because the guard only fires when a nonzero ST leg is supplied
        (uint256 quoteOnlyPreview,) = liquidityTranche.previewDepositMultiAsset(0, quoteAssets);
        assertGt(quoteOnlyPreview, 0, "a quote-only deposit must still preview a positive share amount");
        quoteToken.mint(LT_PROVIDER, quoteAssets);
        vm.startPrank(LT_PROVIDER);
        quoteToken.approve(address(liquidityTranche), quoteAssets);
        (uint256 quoteOnlyMinted,) = liquidityTranche.depositMultiAsset(0, quoteAssets, 0, LT_PROVIDER);
        vm.stopPrank();
        assertEq(quoteOnlyMinted, quoteOnlyPreview, "a quote-only deposit must execute and mint exactly the previewed shares");
    }

    /// @notice Preview equals execution for a senior-only deposit leg: the unbalanced add's fee-bearing side
    ///         must flow identically through the preview and the execution
    function test_LTDepositMultiAsset_SeniorOnlyLeg_PreviewMatchesExecution() public {
        address actor = LT_PROVIDER;
        uint256 stAssets = 50e18;
        stJtVault.mintShares(actor, stAssets);
        vm.prank(actor);
        stJtVault.approve(address(liquidityTranche), stAssets);

        (uint256 previewShares,) = liquidityTranche.previewDepositMultiAsset(stAssets, 0);
        vm.prank(actor);
        (uint256 minted,) = liquidityTranche.depositMultiAsset(stAssets, 0, 0, actor);
        assertEq(minted, previewShares, "a senior-only deposit must mint exactly the previewed shares");
    }

    /// @notice A genuine venue failure inside a preview bubbles out verbatim instead of decoding as a result,
    ///         and previews compose inside a state-mutating transaction, a context the Vault's query mode cannot serve
    function test_MultiAssetPreviews_BubbleGenuineVenueFailures_AndComposeMidTransaction() public {
        // A forced venue failure must surface as itself through every preview path
        balancerVault.setRevertMode(MockBalancerVault.RevertMode.REMOVE);
        try liquidityTranche.previewRedeemMultiAsset(1e18) returns (AssetClaims memory, uint256) {
            fail("the removal preview must bubble a venue failure");
        } catch (bytes memory err) {
            assertEq(bytes4(err), MockBalancerVault.FORCED_REMOVE_REVERT.selector, "the venue's revert must bubble out of the removal preview");
        }
        try liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER) returns (uint256) {
            fail("the multi-asset maximum must bubble a venue failure from its relief preview");
        } catch (bytes memory err) {
            assertEq(bytes4(err), MockBalancerVault.FORCED_REMOVE_REVERT.selector, "the venue's revert must bubble out of the maximum");
        }
        balancerVault.setRevertMode(MockBalancerVault.RevertMode.ADD);
        try liquidityTranche.previewDepositMultiAsset(1e18, QUOTE_UNIT) returns (uint256, uint256) {
            fail("the add preview must bubble a venue failure");
        } catch (bytes memory err) {
            assertEq(bytes4(err), MockBalancerVault.FORCED_ADD_REVERT.selector, "the venue's revert must bubble out of the add preview");
        }
        balancerVault.setRevertMode(MockBalancerVault.RevertMode.NONE);

        // Mutate, preview, then mutate again inside one transaction, the Vault's query mode requires a zeroed
        // transaction origin, so this composition is only possible on the execute-and-revert transport
        assertTrue(tx.origin != address(0), "the composition must run in a context the Vault's query mode rejects");
        uint256 quoteAssets = 100 * QUOTE_UNIT;
        quoteToken.mint(LT_PROVIDER, quoteAssets);
        vm.startPrank(LT_PROVIDER);
        quoteToken.approve(address(liquidityTranche), quoteAssets);
        liquidityTranche.depositMultiAsset(0, quoteAssets, 0, LT_PROVIDER);
        uint256 maxShares = liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER);
        (, uint256 previewQuote) = liquidityTranche.previewRedeemMultiAsset(maxShares);
        (, uint256 quoteOut) = liquidityTranche.redeemMultiAsset(maxShares, 0, 0, LT_PROVIDER, LT_PROVIDER);
        vm.stopPrank();
        assertEq(quoteOut, previewQuote, "the mid-transaction preview must match the execution that follows it");
    }

    /// @notice Post-op gate parity on the redemption side: a redemption sized just past the multi-asset maximum
    ///         reverts LIQUIDITY_REQUIREMENT_VIOLATED from the preview exactly as from the execution, because the
    ///         preview runs the same post-op enforcement at the venue-marked LT raw NAV
    function test_RevertIf_RedeemMultiAssetBreachesLiquidity_PreviewAndExecution() public {
        uint256 maxShares = liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER);
        assertGt(maxShares, 0, "the fixture must leave multi-asset redemption capacity");

        // The boundary test's breach sizing: slack for the accountant's one-NAV-wei dust tolerance plus the
        // flow's quote and share quantization floors, kept inside the balance so the gate, not the clamp, decides
        uint256 breachShares =
            maxShares + Math.mulDiv(2e12 + 1, liquidityTranche.totalSupply(), toUint256(accountant.getState().lastLTRawNAV), Math.Rounding.Ceil) + 2;
        assertLt(breachShares, liquidityTranche.balanceOf(LT_PROVIDER), "the breach probe must sit inside the owner's balance");

        // The preview bubbles the post-op liquidity gate for the doomed size, leaving every ledger untouched
        bytes32 digestBefore = _marketDigest(LT_PROVIDER);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        liquidityTranche.previewRedeemMultiAsset(breachShares);
        assertEq(_marketDigest(LT_PROVIDER), digestBefore, "the gate-reverted preview left a trace on the market");

        // The same size executes into the same post-op liquidity gate
        vm.prank(LT_PROVIDER);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        liquidityTranche.redeemMultiAsset(breachShares, 0, 0, LT_PROVIDER, LT_PROVIDER);
    }

    /// @notice Post-op gate parity on the deposit side: an ST leg sized past the market's senior capacity reverts
    ///         COVERAGE_REQUIREMENT_VIOLATED from the preview exactly as from the execution, because the preview
    ///         runs the same post-op enforcement at the venue-marked LT raw NAV
    function test_RevertIf_DepositMultiAssetBreachesCoverage_PreviewAndExecution() public {
        // Double the coverage-bound senior capacity breaches coverage outright: the ST leg raises the senior
        // raw NAV the junior buffer must cover, and the liquidity side only deepens, so coverage is what fires
        uint256 stLeg = toUint256(seniorTranche.maxDeposit(LT_PROVIDER)) * 2;
        assertGt(stLeg, 0, "the fixture must leave senior deposit capacity to double");

        // The preview bubbles the post-op coverage gate for the doomed deposit, leaving every ledger untouched
        bytes32 digestBefore = _marketDigest(LT_PROVIDER);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        liquidityTranche.previewDepositMultiAsset(stLeg, 0);
        assertEq(_marketDigest(LT_PROVIDER), digestBefore, "the gate-reverted preview left a trace on the market");

        // The same deposit executes into the same post-op coverage gate
        stJtVault.mintShares(LT_PROVIDER, stLeg);
        vm.startPrank(LT_PROVIDER);
        stJtVault.approve(address(liquidityTranche), stLeg);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        liquidityTranche.depositMultiAsset(stLeg, 0, 0, LT_PROVIDER);
        vm.stopPrank();
    }
}
