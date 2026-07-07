// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "../../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

import { IRouter } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IRouter.sol";
import { BasePoolMath } from "../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BasePoolMath.sol";

import { IRoycoDayAccountant } from "../../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../../src/interfaces/IRoycoDayKernel.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { SyncedAccountingState } from "../../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { Test_BalancerSwapRateOracleBase } from "./Test_BalancerSwapRateOracleBase.t.sol";

/**
 * @title Test_BalancerLPGateReinvestBase
 * @notice Fork tests for external LPing through the canonical Router, the liquidity gate on real oracle
 *         numbers, the reinvestment fee decomposition on real E-CLP math, proportional-remove composition
 *         after skew, and FIXED_TERM x the pool. Chains linearly on the swap/rate/oracle suite so one
 *         concrete leaf carries the whole deep-venue fork suite.
 */
abstract contract Test_BalancerLPGateReinvestBase is Test_BalancerSwapRateOracleBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // SHARED ARRANGE HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Funds an external actor with the proportional amounts (2% padded) for an exact-BPT-out add and executes it.
    function _externalProportionalPosition(string memory _name, uint256 _exactBptOut) internal returns (address actor) {
        actor = _makeExternalLP(_name);
        uint256[] memory rawBalances = _rawBalances();
        uint256 supply = _bptSupply();
        uint256 stNeeded = Math.mulDiv(rawBalances[_stPoolIndex()], _exactBptOut, supply) * 102 / 100 + 2;
        uint256 quoteNeeded = Math.mulDiv(rawBalances[_quotePoolIndex()], _exactBptOut, supply) * 102 / 100 + 2;
        _fundExternalLP(actor, stNeeded, quoteNeeded);
        _externalAddProportional(actor, _exactBptOut);
    }

    /**
     * @dev The committed liquidity utilization re-derived from the committed checkpoint with plain checked
     *      integer arithmetic (the ceiling division written out), sharing no math library with production:
     *      utilization is the depth the senior tranche requires (`stEffectiveNAV * minLiquidity`) over the
     *      pooled depth backing it (`ltRawNAV`), rounded up in favor of reading a breach. Products stay far
     *      below 2^256 on this suite's NAV domain, so the checked multiply cannot overflow.
     */
    function _committedLiquidityUtilization() internal view returns (uint256) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 stEff = toUint256(a.lastSTEffectiveNAV);
        uint256 ltRaw = toUint256(a.lastLTRawNAV);
        if (stEff == 0 || a.minLiquidityWAD == 0) return 0; // no senior claim or no requirement: nothing to back
        if (ltRaw == 0) return type(uint256).max; // a live requirement against zero depth is unboundedly breached
        return (stEff * uint256(a.minLiquidityWAD) + ltRaw - 1) / ltRaw;
    }

    /**
     * @dev Drives the committed liquidity utilization above WAD through real senior yield: the LT premium is
     *      disabled (`maxLTYieldShareWAD = 0`) so nothing restores the pool, and each yield step raises the
     *      senior mark faster than the rate-scaled pool depth. Fails loudly if the breach is not reached.
     */
    function _arrangeYieldDrivenLiquidityBreach() internal {
        _sync();
        _enableLTOverlay(0.1e18, 0, _minLiquidityForTargetUtilization(0.99e18));
        for (uint256 i = 0; i < 20; ++i) {
            _warpForward(1 days);
            _applySTYield(0.02e18);
            _sync();
            if (_committedLiquidityUtilization() > WAD) return;
        }
        fail("arrange: senior yield did not push the liquidity utilization past WAD within the budget");
    }

    /// @dev Measures the total NAV value a multi-asset LT redemption pays `_lp` (ST-asset + quote balance diffs).
    function _measureRedeemValueMulti(address _lp, uint256 _shares) internal returns (uint256 valueNAV) {
        uint256 stAssetBal0 = IERC20(testConfig.stAsset).balanceOf(_lp);
        uint256 quoteBal0 = IERC20(testConfig.quoteAsset).balanceOf(_lp);
        uint256 stShareBal0 = ST.balanceOf(_lp);
        _doRedeemLTMulti(_lp, _shares, 0, 0);
        valueNAV = toUint256(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(IERC20(testConfig.stAsset).balanceOf(_lp) - stAssetBal0)))
            + _quoteToNAV(IERC20(testConfig.quoteAsset).balanceOf(_lp) - quoteBal0) + _stSharesToNAVAtRate(ST.balanceOf(_lp) - stShareBal0, _kernelRate());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EXTERNAL LP THROUGH THE CANONICAL ROUTER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice an external unbalanced add syncs the kernel through the hook exactly once and never
    ///         touches the kernel's owned-BPT ledger; the minted BPT lands with the external actor.
    function test_ExternalAddUnbalanced_syncs_kernelLedgerUntouched() public {
        _seedForSwaps();
        _sync();
        uint256 ltOwned0 = toUint256(KERNEL.getState().ltOwnedYieldBearingAssets);
        uint256 supply0 = _bptSupply();

        address actor = _makeExternalLP("EXTERNAL_UNBALANCED_ADDER");
        uint256 stShares = _rawBalances()[_stPoolIndex()] / 20;
        uint256 quoteAssets = _rawBalances()[_quotePoolIndex()] / 20;
        _fundExternalLP(actor, stShares, quoteAssets);

        vm.recordLogs();
        uint256 bptOut = _externalAddUnbalanced(actor, stShares, quoteAssets, 0);
        (uint256 syncCount,) = _lastLogData(vm.getRecordedLogs(), address(ACCOUNTANT), IRoycoDayAccountant.TrancheAccountingSynced.selector);

        assertEq(syncCount, 1, "the before-add hook must sync the kernel exactly once");
        assertEq(toUint256(KERNEL.getState().ltOwnedYieldBearingAssets), ltOwned0, "an external add must not move the kernel's owned-BPT ledger");
        assertEq(IERC20(POOL).balanceOf(actor), bptOut, "the minted BPT must land with the external actor");
        assertEq(_bptSupply(), supply0 + bptOut, "the BPT supply must grow by exactly the external mint");
    }

    /**
     * @notice an external SINGLE-SIDED add's realized cost matches the derived leak law
     *         `(1 - w) * V * (f + (1 - q))`: the imbalanced portion pays the swap fee AND is absorbed at the
     *         pool's internal marginal price q instead of the feed mark. The kernel's LT raw NAV weakly gains.
     * @dev Economics on the FEED-price basis (both legs of the comparison marked the same way): the minted
     *      BPT's pro-rata claim on the pool's mark-to-market vs the contributed value at the same marks.
     *      Expectation source: `_expectedSingleSidedAddLeak` (derivation in the helper).
     */
    function test_ExternalAddSingleSidedST_paysTheLT_leakWithinBound() public {
        _seedForSwaps();
        _sync();
        uint256 w0 = _stValueShareWAD();
        uint256 spot0 = _spotSTinQuoteWAD();
        uint256 ltRaw0 = toUint256(LT.getRawNAV());

        address actor = _makeExternalLP("EXTERNAL_SINGLE_SIDED_ADDER");
        uint256 stShares = _rawBalances()[_stPoolIndex()] / 20;
        _fundExternalLP(actor, stShares, 0);
        uint256 valueIn = _stSharesToNAVAtRate(stShares, _kernelRate());

        uint256 bptOut = _externalAddUnbalanced(actor, stShares, 0, 0);

        uint256 mintedValue = Math.mulDiv(bptOut, _mtmPerBPTWAD(), WAD);
        int256 leak = int256(valueIn) - int256(mintedValue);
        (int256 expectedLeak, uint256 slack) = _expectedSingleSidedAddLeak(valueIn, w0, spot0, _spotSTinQuoteWAD());
        assertApproxEqAbs(leak, expectedLeak, slack, "the adder's realized leak must match (1-w)*V*(f + (1-q))");

        // Oracle-basis sanity: the kernel's LT mark can only gain from an external add.
        assertGe(toUint256(LT.getRawNAV()) + _tol2(), ltRaw0, "an external add can never dilute the kernel's LT mark");
    }

    /// @notice an external PROPORTIONAL add is value-neutral to everyone else: NAV-per-BPT and the
    ///         kernel's LT raw NAV are unchanged (up to pool-favoring rounding).
    function test_ExternalAddProportional_navPerBPTConstant() public {
        _seedForSwaps();
        _sync();
        uint256 navPerBPT0 = _navPerBPTWAD();
        uint256 ltRaw0 = toUint256(LT.getRawNAV());

        _externalProportionalPosition("EXTERNAL_PROPORTIONAL_ADDER", _bptSupply() / 10);

        assertGe(_navPerBPTWAD() + 2, navPerBPT0, "a proportional add must not dilute NAV per BPT (rounding favors the pool)");
        assertApproxEqAbs(toUint256(LT.getRawNAV()), ltRaw0, _tol2(), "a proportional add must leave the kernel's LT mark unchanged");
    }

    /**
     * @notice FINDING 10 — the pool's LP set is PERMISSIONLESS and the liquidity gate is blind to venue
     *         depth. The intended posture was a kernel-only LP set, so external mint and burn could never move
     *         the gate's inputs without the kernel knowing. Actual behavior: anyone can LP
     *         through the canonical Router, and an external LP holding half the pool can exit in full —
     *         unrestricted by any Royco gate — draining half the REAL tradable depth while the committed
     *         liquidity utilization (which values only kernel-owned BPT at NAV-per-BPT, invariant under a
     *         proportional burn) does not move. The gate guarantees the kernel's INVENTORY VALUE, not venue depth.
     */
    function test_FINDING_10_poolPermissionless_externalExitDrainsDepthGateBlind() public {
        _seedForSwaps();
        _sync();
        address actor = _externalProportionalPosition("EXTERNAL_MAJORITY_LP", _bptSupply()); // owns 50% post-mint
        _driveLiquidityUtilizationTo(0.95e18);

        uint256 utilBefore = _committedLiquidityUtilization();
        uint256 ltRawBefore = toUint256(ACCOUNTANT.getState().lastLTRawNAV);
        uint256 depthBefore = _markToMarketAtFeeds();

        // The external LP exits its ENTIRE position: no Royco gate is consulted, the exit cannot revert.
        _externalRemoveProportional(actor, IERC20(POOL).balanceOf(actor));

        uint256 depthAfter = _markToMarketAtFeeds();
        assertLe(depthAfter, Math.mulDiv(depthBefore, 55, 100), "FINDING: half the real tradable depth left the venue");

        _sync();
        assertLe(_committedLiquidityUtilization(), utilBefore + 1, "FINDING: the liquidity utilization did not move (the gate is depth-blind)");
        assertApproxEqAbs(toUint256(ACCOUNTANT.getState().lastLTRawNAV), ltRawBefore, _tol2(), "the committed LT mark is invariant under the external burn");
    }

    /**
     * @notice an external single-token exit pays the imbalance fee to the remaining LPs: NAV-per-BPT
     *         weakly rises and the kernel's gain is bounded by its pool share of the exit's fee + curvature.
     */
    function test_ExternalRemoveSingleToken_feeAccruesToRemainers() public {
        _seedForSwaps();
        _sync();
        address actor = _externalProportionalPosition("EXTERNAL_SINGLE_EXITER", _bptSupply() / 5);

        uint256 navPerBPT0 = _navPerBPTWAD();
        uint256 ltRaw0 = toUint256(LT.getRawNAV());
        uint256 spot0 = _spotSTinQuoteWAD();
        uint256 quoteShare0 = WAD - _stValueShareWAD();
        uint256 phi0 = _kernelPoolShareWAD();

        uint256 bptIn = IERC20(POOL).balanceOf(actor) / 2;
        uint256 exitValue = Math.mulDiv(bptIn, navPerBPT0, WAD);
        _externalRemoveSingleTokenExactIn(actor, bptIn, testConfig.quoteAsset);

        assertGe(_navPerBPTWAD() + 2, navPerBPT0, "a single-token exit must pay the remainers, never dilute them");
        uint256 ltRaw1 = toUint256(LT.getRawNAV());
        assertGe(ltRaw1 + _tol2(), ltRaw0, "the kernel's LT mark must weakly gain from the exit fee");
        // Upper bound: the kernel's share of the exit's fee + internal-price leak (the exit-side analogue of
        // the add leak law: the withdrawn single token is priced internally, in [alpha, beta]), padded by the
        // oracle re-mark drift the exit's composition skew can move (within (1 - alpha) of the exit value).
        (uint256 alpha,) = _stPriceBandWAD();
        (int256 expectedLeak, uint256 slack) = _expectedSingleSidedAddLeak(exitValue, quoteShare0, spot0, _spotSTinQuoteWAD());
        uint256 leakHi = uint256(expectedLeak > int256(0) ? expectedLeak : -expectedLeak) + slack;
        uint256 remarkSlack = Math.mulDiv(exitValue, WAD - alpha, WAD);
        assertLe(
            ltRaw1 - Math.min(ltRaw1, ltRaw0),
            Math.mulDiv(phi0, leakHi, WAD) + remarkSlack + _tol2(),
            "the kernel's gain is bounded by its exit-leak share plus the oracle re-mark drift"
        );
    }

    /**
     * @notice external depth is economically inert to a kernel redeemer: a multi-asset LT redemption pays
     *         the identical value whether or not a large external LP position sits in the pool (A/B snapshot).
     */
    function test_ExternalDepth_isInertToKernelRedeemer() public {
        _seedForSwaps();
        _sync();
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 4;

        uint256 snapshotId = vm.snapshotState();
        uint256 valueWithout = _measureRedeemValueMulti(LT_ALICE_ADDRESS, shares);
        vm.revertToState(snapshotId);

        _externalProportionalPosition("EXTERNAL_BYSTANDER_LP", _bptSupply()); // doubles the pool around the redeemer
        uint256 valueWith = _measureRedeemValueMulti(LT_ALICE_ADDRESS, shares);

        assertApproxEqAbs(valueWith, valueWithout, 2 * _tol2(), "a kernel redemption's value must be independent of external depth");
    }

    /// @notice a paused hook blocks BOTH external add and external remove (the `router != kernel` path of
    ///         each before-hook syncs `whenNotPaused`), completing the pause blast-radius picture of the hook-pause swap test.
    /// @dev The Router calls are inlined (amounts prebuilt) so `expectRevert` targets the Router call itself
    ///      and not a helper's read of the Vault.
    function test_RevertIf_ExternalAddRemoveWhileHookPaused() public {
        _seedForSwaps();
        _sync();
        address actor = _externalProportionalPosition("EXTERNAL_PAUSED_LP", _bptSupply() / 10);
        uint256 stShares = _rawBalances()[_stPoolIndex()] / 50;
        _fundExternalLP(actor, stShares, 0);
        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[_stPoolIndex()] = stShares;
        uint256 bptToBurn = IERC20(POOL).balanceOf(actor) / 2;
        IRouter router = IRouter(_balancerV3Router());

        _pauseHook();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(actor);
        router.addLiquidityUnbalanced(POOL, exactAmountsIn, 0, false, "");
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(actor);
        router.removeLiquidityProportional(POOL, bptToBurn, new uint256[](2), false, "");
    }

    /// @notice Balancer's unbalanced-add invariant-ratio cap (5x) is the hard bound behind the seed
    ///         helpers' 3x chunk rule: a single external add of ~6x the pool's value reverts.
    function test_RevertIf_ExternalAddUnbalancedBeyondInvariantRatioCap() public {
        _seedForSwaps();
        _sync();
        uint256 mtm = _markToMarketAtFeeds();
        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[_stPoolIndex()] = Math.mulDiv(mtm, 3e18, _kernelRate()); // ~3x pool value in senior shares
        exactAmountsIn[_quotePoolIndex()] = Math.mulDiv(mtm * 3, _quoteScale(), WAD); // ~3x pool value in quote

        address actor = _makeExternalLP("EXTERNAL_WHALE_ADDER");
        _fundExternalLP(actor, exactAmountsIn[_stPoolIndex()], exactAmountsIn[_quotePoolIndex()]);
        IRouter router = IRouter(_balancerV3Router());
        vm.expectPartialRevert(BasePoolMath.InvariantRatioAboveMax.selector);
        vm.prank(actor);
        router.addLiquidityUnbalanced(POOL, exactAmountsIn, 0, false, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // THE LIQUIDITY GATE ON REAL ORACLE NUMBERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice the committed liquidity utilization equals the independent ceil-mirror
     *         `ceil(stEffectiveNAV * minLiq / ltRawNAV)` on REAL oracle inputs, across seeded, skewed, externally-deepened,
     *         and yield-moved states. Exact equality on every state.
     */
    function test_LiquidityGate_utilMatchesMirror_acrossRealStates() public {
        _seedForSwaps();
        _driveLiquidityUtilizationTo(0.8e18);
        _assertPacketUtilMatchesMirror("seeded state");

        _skewPool(true, 0.5e18);
        _assertPacketUtilMatchesMirror("skewed state");

        _externalProportionalPosition("EXTERNAL_E1_LP", _bptSupply() / 5);
        _assertPacketUtilMatchesMirror("externally deepened state");

        _warpForward(1 days);
        _applySTYield(0.01e18);
        _assertPacketUtilMatchesMirror("yield-moved state");
    }

    /// @dev Syncs and asserts the returned packet's liquidity utilization against the ceil-mirror recomputed
    ///      from the packet's own inputs, and cross-checks the packet inputs against the committed checkpoint.
    function _assertPacketUtilMatchesMirror(string memory _ctx) internal {
        SyncedAccountingState memory s = _syncWithState();
        assertEq(
            s.liquidityUtilizationWAD,
            _expectedLiquidityUtilization(s.stEffectiveNAV, uint64(s.minLiquidityWAD), s.ltRawNAV),
            string.concat("packet liquidity utilization vs the independent ceil-mirror: ", _ctx)
        );
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(s.ltRawNAV, a.lastLTRawNAV, string.concat("packet LT mark vs committed checkpoint: ", _ctx));
        assertEq(s.stEffectiveNAV, a.lastSTEffectiveNAV, string.concat("packet senior mark vs committed checkpoint: ", _ctx));
        assertGt(toUint256(a.lastLTRawNAV), 0, string.concat("arrange: the committed LT mark must be live: ", _ctx));
    }

    /**
     * @notice the liquidity gate binds senior entry at exactly WAD on real numbers and is RELEASED by real
     *         LT depth: a senior deposit sized past the committed headroom reverts
     *         `LIQUIDITY_REQUIREMENT_VIOLATED`, and succeeds after an LT deposit deepens the real pool.
     */
    function test_LiquidityGate_stDeposit_bindsAtWAD_releasedByLTDeposit() public {
        _seedForSwaps();
        _driveLiquidityUtilizationTo(0.99e18);

        // Headroom from the committed checkpoint: util <= WAD  <=>  stEffectiveNAV <= ltRawNAV * WAD / minLiq.
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 headroomNAV = Math.mulDiv(toUint256(a.lastLTRawNAV), WAD, a.minLiquidityWAD) - toUint256(a.lastSTEffectiveNAV);
        uint256 breachAssets = toUint256(KERNEL.stConvertNAVUnitsToTrancheUnits(toNAVUnits(headroomNAV))) * 101 / 100 + 10;

        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), breachAssets);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        ST.deposit(toTrancheUnits(breachAssets), ST_BOB_ADDRESS);
        vm.stopPrank();

        // Real LT depth releases the gate: deepen the pool ~25%, then the identical deposit clears.
        _seedLTBalanced(LT_BOB_ADDRESS, _rawBalances()[_stPoolIndex()] / 4);
        uint256 shares = _doDepositST(ST_BOB_ADDRESS, breachAssets).shares;
        assertGt(shares, 0, "the identical senior deposit must clear once real depth backs it");
        assertLe(_committedLiquidityUtilization(), WAD, "the post-deposit committed utilization must respect the gate");
    }

    /**
     * @notice a purely yield-driven breach (no one acted) blocks depth-reducing LT redemptions and senior
     *         entry, leaves junior entry ungated, and releases on a real LT deposit. The gate binds on the
     *         committed post-op state, whichever force moved it.
     */
    function test_LiquidityGate_yieldDrivenBreach_blocksLTRedeemAndSTDeposit() public {
        _seedForSwaps();
        _arrangeYieldDrivenLiquidityBreach();

        // Depth-reducing LT redemption: blocked.
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 10;
        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        LT.redeem(shares, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);

        // Senior entry: blocked while under-provisioned.
        uint256 stAssets = testConfig.initialFunding / 1000;
        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), stAssets);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        ST.deposit(toTrancheUnits(stAssets), ST_BOB_ADDRESS);
        vm.stopPrank();

        // Junior entry: never liquidity-gated.
        assertGt(_doDepositJT(JT_BOB_ADDRESS, testConfig.initialFunding / 1000).shares, 0, "junior entry must stay ungated by liquidity");

        // A real LT deposit heals the metric and releases the redemption.
        _seedLTBalanced(LT_BOB_ADDRESS, _rawBalances()[_stPoolIndex()] / 4);
        assertLe(_committedLiquidityUtilization(), WAD, "arrange: the deepening must heal the utilization");
        vm.prank(LT_ALICE_ADDRESS);
        LT.redeem(shares, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REINVESTMENT FEE DECOMPOSITION ON REAL E-CLP MATH
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The staged idle liquidity premium's NAV value at the committed senior mark (the venue's own reinvest basis).
    function _idleLiquidityPremiumValueNAV() internal view returns (uint256 idleShares, uint256 idleValueNAV) {
        idleShares = KERNEL.getState().ltOwnedSeniorTrancheShares;
        idleValueNAV = toUint256(_expectedValue(idleShares, ST.totalSupply(), ACCOUNTANT.getState().lastSTEffectiveNAV));
    }

    /// @dev Executes the permissioned manual reinvest of the full idle balance and returns the decoded event args.
    function _manualReinvestAll() internal returns (uint256 stSharesReinvested, uint256 ltAssetsMinted, uint256 eventCount) {
        vm.recordLogs();
        vm.prank(KERNEL_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(type(uint256).max);
        bytes memory data;
        (eventCount, data) = _lastLogData(vm.getRecordedLogs(), address(KERNEL), IRoycoDayKernel.LiquidityPremiumReinvested.selector);
        if (eventCount > 0) (stSharesReinvested, ltAssetsMinted) = abi.decode(data, (uint256, uint256));
    }

    /**
     * @dev Measures the realized reinvestment haircut on the GATE'S OWN (oracle) basis under a state snapshot:
     *      `h* = 1 - mintedBPT / fairBPT`, where fairBPT is the production minOut's fair conversion of the
     *      idle value at zero slippage. Measurement only — never an assertion source.
     */
    function _probeReinvestHaircutWAD() internal returns (uint256 haircutWAD, uint256 fairBPT) {
        uint256 snapshotId = vm.snapshotState();
        assertTrue(_trySetReinvestmentSlippage(uint64(WAD - 1)), "probe: the slippage seam must open");
        (, uint256 idleValueNAV) = _idleLiquidityPremiumValueNAV();
        fairBPT = toUint256(KERNEL.ltConvertNAVUnitsToTrancheUnits(toNAVUnits(idleValueNAV)));
        (, uint256 ltAssetsMinted, uint256 eventCount) = _manualReinvestAll();
        assertEq(eventCount, 1, "probe: the wide-open gate must deploy the premium");
        haircutWAD = ltAssetsMinted >= fairBPT ? 0 : WAD - Math.mulDiv(ltAssetsMinted, WAD, fairBPT);
        vm.revertToState(snapshotId);
    }

    /**
     * @notice reinvest wealth conservation: deploying the staged premium moves EXACTLY its value into the
     *         pool minus the protocol's aggregate fee skim — nothing else leaves the system, and bystander LPs
     *         can only gain.
     * @dev Identity at feed marks: `d(pool MtM) == idleValue - aggregateSkim`, with the skim measured from the
     *      Vault's own aggregate-fee counters (valued at the feed marks: ST at the frozen rate, quote at 1.0).
     */
    function test_Reinvest_wealthConservation_identity() public {
        _arrangeReinvestableIdleLiquidityPremium();
        assertTrue(_trySetReinvestmentSlippage(uint64(WAD - 1)), "arrange: the slippage gate must open");
        (, uint256 idleValueNAV) = _idleLiquidityPremiumValueNAV();
        uint256 mtm0 = _markToMarketAtFeeds();
        uint256 mtmPerBPT0 = _mtmPerBPTWAD();
        uint256 skimST0 = VAULT.getAggregateSwapFeeAmount(POOL, IERC20(address(ST)));
        uint256 skimQuote0 = VAULT.getAggregateSwapFeeAmount(POOL, IERC20(testConfig.quoteAsset));

        (,, uint256 eventCount) = _manualReinvestAll();
        assertEq(eventCount, 1, "the open-gate reinvest must deploy");

        uint256 skimValue = _stSharesToNAVAtRate(VAULT.getAggregateSwapFeeAmount(POOL, IERC20(address(ST))) - skimST0, _kernelRate())
            + _quoteToNAV(VAULT.getAggregateSwapFeeAmount(POOL, IERC20(testConfig.quoteAsset)) - skimQuote0);
        assertApproxEqAbs(
            _markToMarketAtFeeds() - mtm0, idleValueNAV - skimValue, 2 * _tol2(), "the pool must absorb exactly the premium value net of the protocol skim"
        );
        assertGe(_mtmPerBPTWAD() + 2, mtmPerBPT0, "bystander LPs can only gain from the kernel's single-sided deploy");
    }

    /**
     * @notice the reinvest obeys the single-sided leak law through the PRODUCTION path: the value the LT
     *         gives up deploying the premium is `(1 - w) * V * (f + (1 - q))` — the imbalance fee plus the
     *         internal-price discount — measured at feed marks.
     */
    function test_Reinvest_leakMatchesSingleSidedLaw() public {
        _arrangeReinvestableIdleLiquidityPremium();
        assertTrue(_trySetReinvestmentSlippage(uint64(WAD - 1)), "arrange: the slippage gate must open");
        _sync();
        (, uint256 idleValueNAV) = _idleLiquidityPremiumValueNAV();
        uint256 w0 = _stValueShareWAD();
        uint256 spot0 = _spotSTinQuoteWAD();

        (, uint256 ltAssetsMinted, uint256 eventCount) = _manualReinvestAll();
        assertEq(eventCount, 1, "the open-gate reinvest must deploy");

        uint256 mintedValue = Math.mulDiv(ltAssetsMinted, _mtmPerBPTWAD(), WAD);
        int256 leak = int256(idleValueNAV) - int256(mintedValue);
        (int256 expectedLeak, uint256 slack) = _expectedSingleSidedAddLeak(idleValueNAV, w0, spot0, _spotSTinQuoteWAD());
        assertApproxEqAbs(leak, expectedLeak, slack, "the reinvest leak must match (1-w)*V*(f + (1-q))");
    }

    /**
     * @notice the slippage gate flips at exactly the measured real-math haircut h*: a threshold below h*
     *         tolerates the failure (no event, shares stay idle, the call itself succeeds), a threshold above
     *         h* deploys. The gate boundary is the venue's realized execution, not a modeled figure.
     */
    function test_Reinvest_gateFlipsAtMeasuredHaircut() public {
        _arrangeReinvestableIdleLiquidityPremium();
        (uint256 haircut,) = _probeReinvestHaircutWAD();
        assertGt(haircut, 0, "arrange: the real venue must charge a nonzero haircut");
        (uint256 idleShares0,) = _idleLiquidityPremiumValueNAV();

        // Below the realized haircut: tolerated failure — the call succeeds, nothing moves.
        assertTrue(_trySetReinvestmentSlippage(uint64(Math.mulDiv(haircut, 9, 10))), "arrange: set the gate below h*");
        (,, uint256 eventCount) = _manualReinvestAll();
        assertEq(eventCount, 0, "a gate tighter than the realized haircut must tolerate-fail");
        assertEq(KERNEL.getState().ltOwnedSeniorTrancheShares, idleShares0, "the premium must stay staged");

        // Above it: deploys in full.
        assertTrue(_trySetReinvestmentSlippage(uint64(Math.min(Math.mulDiv(haircut, 11, 10), WAD - 1))), "arrange: set the gate above h*");
        (uint256 stSharesReinvested,, uint256 eventCount2) = _manualReinvestAll();
        assertEq(eventCount2, 1, "a gate looser than the realized haircut must deploy");
        assertEq(stSharesReinvested, idleShares0, "the entire staged premium must deploy");
        assertEq(KERNEL.getState().ltOwnedSeniorTrancheShares, 0, "the idle ledger must zero");
    }

    /**
     * @notice the SHIPPED slippage default (the market config's 10bp) clears the realized haircut on a
     *         near-peg pool with comfortable margin: h* < 10bp, and the reinvest deploys at exactly the
     *         deployed configuration. Grounds the production parameter choice in measured venue math.
     */
    function test_Reinvest_shippedSlippageDefault_passesOnNearPegPool() public {
        _arrangeReinvestableIdleLiquidityPremium();
        (uint256 haircut,) = _probeReinvestHaircutWAD();
        uint64 shippedSlippageWAD = 0.001e18; // MarketDeploymentConfig's maxReinvestmentSlippageWAD (10bp)
        assertLt(haircut, shippedSlippageWAD, "the near-peg realized haircut must sit under the shipped 10bp gate");

        assertTrue(_trySetReinvestmentSlippage(shippedSlippageWAD), "arrange: restore the shipped gate");
        (,, uint256 eventCount) = _manualReinvestAll();
        assertEq(eventCount, 1, "the shipped configuration must deploy the premium on a healthy pool");
        assertEq(KERNEL.getState().ltOwnedSeniorTrancheShares, 0, "the idle ledger must zero under the shipped gate");
    }

    /**
     * @notice the leak law holds across pool composition states: the reinvest's realized leak matches
     *         `(1 - w) * V * (f + (1 - q))` recomputed per state, for a quote-heavy and an ST-heavy pool.
     * @dev The two skews change both `w` (the imbalance fraction) and `q` (the internal absorption price) in
     *      opposite directions — asserting the LAW per state is strictly stronger than a monotonicity guess.
     */
    function test_Reinvest_leakLawHolds_acrossSkewStates() public {
        _arrangeReinvestableIdleLiquidityPremium();
        assertTrue(_trySetReinvestmentSlippage(uint64(WAD - 1)), "arrange: the slippage gate must open");

        uint256 snapshotId = vm.snapshotState();
        _skewPool(true, 0.5e18); // quote-heavy: ST leg depleted, q toward beta
        _assertReinvestLeakMatchesLaw("quote-heavy pool");
        vm.revertToState(snapshotId);

        _skewPool(false, 0.5e18); // ST-heavy: ST leg saturated, q toward alpha
        _assertReinvestLeakMatchesLaw("ST-heavy pool");
    }

    /// @dev Executes the full-idle reinvest and asserts its feed-basis leak against the law for the current state.
    function _assertReinvestLeakMatchesLaw(string memory _ctx) internal {
        _sync();
        (, uint256 idleValueNAV) = _idleLiquidityPremiumValueNAV();
        assertGt(idleValueNAV, 0, string.concat("arrange: a staged premium must exist: ", _ctx));
        uint256 w0 = _stValueShareWAD();
        uint256 spot0 = _spotSTinQuoteWAD();

        (, uint256 ltAssetsMinted, uint256 eventCount) = _manualReinvestAll();
        assertEq(eventCount, 1, string.concat("the open-gate reinvest must deploy: ", _ctx));

        int256 leak = int256(idleValueNAV) - int256(Math.mulDiv(ltAssetsMinted, _mtmPerBPTWAD(), WAD));
        (int256 expectedLeak, uint256 slack) = _expectedSingleSidedAddLeak(idleValueNAV, w0, spot0, _spotSTinQuoteWAD());
        assertApproxEqAbs(leak, expectedLeak, slack, string.concat("the reinvest leak must match the law: ", _ctx));
    }

    /**
     * @notice the venue's REAL failure mode is tolerated: a premium too large for the pool's unbalanced-add
     *         invariant-ratio cap (a dust-deep pool, the `_arrangeStagedIdleLiquidityPremium` state) reverts inside
     *         Balancer even with the slippage gate wide open; the kernel swallows it, the call succeeds, and
     *         the premium stays staged.
     * @dev Two real-math facts pinned here: (1) the invariant-ratio cap — not the price range — is what rejects
     *      an oversized single-sided deploy (a single-sided ADD never trips `AssetBoundsExceeded`; the range
     *      wall only binds swaps, so a skewed pool executes the deploy and the slippage gate is the ONLY
     *      protection there — `test_Reinvest_leakLawHolds_acrossSkewStates` exercises exactly that); (2) the kernel's ANY-revert-swallowed
     *      contract holds against the real venue error, not just the mock seam.
     */
    function test_Reinvest_invariantRatioCapFailure_tolerated_sharesStayIdle() public {
        _arrangeStagedIdleLiquidityPremium(); // shallow pool with a staged premium (gate shut during staging)

        // Grow the staged premium (gate still shut) until it overruns the venue's 5x invariant-ratio cap:
        // added value must exceed ~4x the pool's value for the ratio bound to reject the deploy.
        uint256 idleValueNAV;
        for (uint256 i = 0; i < 10; ++i) {
            (, idleValueNAV) = _idleLiquidityPremiumValueNAV();
            if (idleValueNAV > Math.mulDiv(_markToMarketAtFeeds(), 42, 10)) break;
            _warpForward(1 days);
            _applySTYield(0.05e18);
            _sync();
        }
        uint256 idleShares0;
        (idleShares0, idleValueNAV) = _idleLiquidityPremiumValueNAV();
        assertGt(idleValueNAV, Math.mulDiv(_markToMarketAtFeeds(), 42, 10), "arrange: the staged premium must overrun the venue's invariant-ratio cap");
        assertTrue(_trySetReinvestmentSlippage(uint64(WAD - 1)), "arrange: the gate must be wide open (failure must come from the venue)");

        (,, uint256 eventCount) = _manualReinvestAll();
        assertEq(eventCount, 0, "the cap-breaching deploy must be swallowed, not bubbled");
        assertEq(KERNEL.getState().ltOwnedSeniorTrancheShares, idleShares0, "the premium must stay staged for the next attempt");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPORTIONAL-REMOVE COMPOSITION AFTER SKEW
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice after swaps skew the reserves, a kernel multi-asset redemption removes both venue legs in
     *         the LIVE pool ratio: each leg's raw removal equals `floor(bptBurned * rawBalance_i / bptSupply)`
     *         (within a wei), and the quote leg lands with the redeemer untouched.
     */
    function test_LTRedeemMulti_afterSkew_removesLegsInLiveRatio() public {
        _seedForSwaps();
        _skewPool(true, 0.6e18);
        _sync();

        uint256[] memory raw0 = _rawBalances();
        uint256 supply0 = _bptSupply();
        uint256 ltOwned0 = toUint256(KERNEL.getState().ltOwnedYieldBearingAssets);
        uint256 redeemerQuote0 = IERC20(testConfig.quoteAsset).balanceOf(LT_ALICE_ADDRESS);

        _doRedeemLTMulti(LT_ALICE_ADDRESS, LT.balanceOf(LT_ALICE_ADDRESS) / 4, 0, 0);

        uint256 bptBurned = ltOwned0 - toUint256(KERNEL.getState().ltOwnedYieldBearingAssets);
        assertGt(bptBurned, 0, "arrange: the redemption must burn a venue slice");
        uint256[] memory raw1 = _rawBalances();
        assertApproxEqAbs(
            raw0[_stPoolIndex()] - raw1[_stPoolIndex()],
            Math.mulDiv(bptBurned, raw0[_stPoolIndex()], supply0),
            1,
            "the ST leg must exit in the live pool ratio (floored)"
        );
        assertApproxEqAbs(
            raw0[_quotePoolIndex()] - raw1[_quotePoolIndex()],
            Math.mulDiv(bptBurned, raw0[_quotePoolIndex()], supply0),
            1,
            "the quote leg must exit in the live pool ratio (floored)"
        );
        assertEq(
            IERC20(testConfig.quoteAsset).balanceOf(LT_ALICE_ADDRESS) - redeemerQuote0,
            raw0[_quotePoolIndex()] - raw1[_quotePoolIndex()],
            "the venue's quote leg must land with the redeemer in full"
        );
    }

    /**
     * @notice after a skew, a multi-asset redeemer is never OVERCHARGED and inherits at most its slice of
     *         the skew premium: received (feed marks) minus charged (the oracle-basis LT share value) sits in
     *         `[-tol, slice * (MtM - TVL) + tol]` — the oracle's min-composition mark can only under-charge.
     */
    function test_LTRedeemMulti_afterSkew_redeemerValueWithinSkewBound() public {
        _seedForSwaps();
        _skewPool(true, 0.6e18);
        _sync();

        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 4;
        uint256 charged = Math.mulDiv(toUint256(LT.totalAssets().nav), shares, LT.totalSupply());
        uint256 ltOwned0 = toUint256(KERNEL.getState().ltOwnedYieldBearingAssets);
        uint256 sliceGapCeiling = Math.mulDiv(
            Math.mulDiv(ltOwned0, shares, LT.totalSupply()), // the BPT slice the redemption burns
            _markToMarketAtFeeds() - _poolTVL(),
            _bptSupply()
        );

        uint256 received = _measureRedeemValueMulti(LT_ALICE_ADDRESS, shares);

        assertGe(received + 2 * _tol2(), charged, "the redeemer must never be overcharged against the oracle mark");
        assertLe(received, charged + sliceGapCeiling + 2 * _tol2(), "the redeemer's bonus is capped by its slice of the MtM-TVL skew gap");
    }

    /// @notice Router-path control for the kernel-redemption leg formula: an EXTERNAL proportional remove returns exactly the
    ///         floored pro-rata raw amounts per leg, on the same skewed reserves.
    function test_ExternalRemoveProportional_afterSkew_amountsExactFloor() public {
        _seedForSwaps();
        _sync();
        address actor = _externalProportionalPosition("EXTERNAL_G3_LP", _bptSupply() / 5);
        _skewPool(true, 0.6e18);

        uint256[] memory raw0 = _rawBalances();
        uint256 supply0 = _bptSupply();
        uint256 bptIn = IERC20(POOL).balanceOf(actor) / 2;

        uint256[] memory amountsOut = _externalRemoveProportional(actor, bptIn);

        assertApproxEqAbs(amountsOut[0], Math.mulDiv(bptIn, raw0[0], supply0), 1, "leg 0 must be the floored pro-rata slice");
        assertApproxEqAbs(amountsOut[1], Math.mulDiv(bptIn, raw0[1], supply0), 1, "leg 1 must be the floored pro-rata slice");
    }

    /**
     * @notice a value-balanced multi-asset deposit into a SKEWED pool pays a bounded entry cost: the
     *         minted LT share value undercuts the contributed value by at most the worst in-range
     *         re-mark plus fee on the whole contribution, and existing LT holders never lose.
     * @dev Coarse bound by design: the deposit's non-proportional portion against a skewed pool is absorbed at
     *      in-range internal prices, so the total cost is capped by `(f + (1 - alpha)) * V`.
     */
    function test_LTDepositMulti_intoSkewedPool_entryCostBounded() public {
        _seedForSwaps();
        _skewPool(true, 0.6e18);
        _sync();
        uint256 sharePrice0 = Math.mulDiv(toUint256(LT.totalAssets().nav), WAD, LT.totalSupply());

        uint256 stLeg = _rawBalances()[_stPoolIndex()] / 10;
        uint256 quoteLeg = _quoteAssetsForValue(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(stLeg)));
        uint256 contributed = toUint256(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(stLeg))) + _quoteToNAV(quoteLeg);

        uint256 shares = _doDepositLTMulti(LT_ALICE_ADDRESS, stLeg, quoteLeg, 0).shares;

        uint256 minted = Math.mulDiv(toUint256(LT.totalAssets().nav), shares, LT.totalSupply());
        assertLe(minted, contributed + _tol2(), "a depositor can never mint more value than it contributed");
        (uint256 alpha,) = _stPriceBandWAD();
        uint256 costCeiling = Math.mulDiv(contributed, _staticSwapFeePctWAD() + (WAD - alpha), WAD);
        assertGe(minted + costCeiling + 2 * _tol2(), contributed, "the entry cost into a skewed pool must stay within fee + worst in-range re-mark");
        assertGe(Math.mulDiv(toUint256(LT.totalAssets().nav), WAD, LT.totalSupply()) + 2, sharePrice0, "existing LT holders can never lose to an entrant");
    }

    /**
     * @notice the in-kind BPT slice is COMPOSITION-INDEPENDENT: an identical in-kind redemption pays the
     *         identical BPT amount with and without a preceding skew (A/B snapshot) — only the multi-asset
     *         unwind sees composition.
     */
    function test_LTRedeem_inKind_bptSliceUnaffectedByComposition() public {
        _seedForSwaps();
        _sync();
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 4;

        uint256 snapshotId = vm.snapshotState();
        uint256 bpt0 = IERC20(POOL).balanceOf(LT_ALICE_ADDRESS);
        _doRedeemLT(LT_ALICE_ADDRESS, shares);
        uint256 bptUnskewed = IERC20(POOL).balanceOf(LT_ALICE_ADDRESS) - bpt0;
        vm.revertToState(snapshotId);

        _skewPool(true, 0.6e18);
        uint256 bpt1 = IERC20(POOL).balanceOf(LT_ALICE_ADDRESS);
        _doRedeemLT(LT_ALICE_ADDRESS, shares);
        uint256 bptSkewed = IERC20(POOL).balanceOf(LT_ALICE_ADDRESS) - bpt1;

        assertEq(bptSkewed, bptUnskewed, "the in-kind BPT slice must not depend on the pool's composition");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FIXED_TERM x THE POOL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice the pool is NOT frozen by a fixed term: external swaps execute in-term, the hook still
    ///         syncs, and the fee still accrues to the BPT within the derived band.
    function test_FixedTerm_externalSwap_functionsAndSyncs() public {
        _seedForSwaps();
        _enterFixedTerm();
        uint256 tvl0 = _poolTVL();

        (address swapper, uint256 amountIn) = _armSwapper(testConfig.quoteAsset, 0.25e18);
        vm.recordLogs();
        uint256 amountOut = _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);
        assertGt(amountOut, 0, "an in-term external swap must execute");

        (uint256 syncCount,) = _lastLogData(vm.getRecordedLogs(), address(ACCOUNTANT), IRoycoDayAccountant.TrancheAccountingSynced.selector);
        assertEq(syncCount, 1, "the hook must still sync in-term");
        (uint256 lo, uint256 hi) = _swapFeeTVLBound(_quoteToNAV(amountIn));
        uint256 tvlDelta = _poolTVL() - tvl0;
        assertGe(tvlDelta, lo, "the in-term swap fee must still accrue to the BPT (band floor)");
        assertLe(tvlDelta, hi, "the in-term swap fee must stay within the band ceiling");
    }

    /// @notice external LP add and remove both function in-term: the venue's LP surface is term-agnostic.
    function test_FixedTerm_externalAddRemove_function() public {
        _seedForSwaps();
        _enterFixedTerm();

        address actor = _externalProportionalPosition("EXTERNAL_IN_TERM_LP", _bptSupply() / 10);
        uint256 bptBal = IERC20(POOL).balanceOf(actor);
        assertGt(bptBal, 0, "an in-term external add must mint");
        uint256[] memory amountsOut = _externalRemoveProportional(actor, bptBal / 2);
        assertGt(amountsOut[0] + amountsOut[1], 0, "an in-term external remove must pay out");
    }

    /**
     * @notice the quote-only multi-asset deposit (the ONLY kernel deposit legal in-term) lands as a real
     *         single-sided QUOTE add and obeys the same leak law on the quote axis:
     *         `(1 - wQuote) * V * (f + (1 - pQuote))` with `pQuote = 1 / q`.
     */
    function test_FixedTerm_quoteOnlyDeposit_realSingleSidedAdd_leakWithinLaw() public {
        _seedForSwaps();
        _enterFixedTerm();
        _sync();

        uint256 quoteShare0 = WAD - _stValueShareWAD();
        uint256 quoteSpot0 = Math.mulDiv(WAD, WAD, _spotSTinQuoteWAD()); // internal price of quote vs its 1.0 feed
        uint256 quoteLeg = _rawBalances()[_quotePoolIndex()] / 10;
        uint256 contributed = _quoteToNAV(quoteLeg);
        uint256 supply0 = LT.totalSupply();
        uint256 nav0 = toUint256(LT.totalAssets().nav);

        uint256 shares = _doDepositLTMulti(LT_ALICE_ADDRESS, 0, quoteLeg, 0).shares;
        assertGt(shares, 0, "the quote-only deposit must mint in-term");

        // The depositor's minted claim: its share fraction of the post-add LT NAV (oracle-consistent mark).
        uint256 minted = Math.mulDiv(toUint256(LT.totalAssets().nav), shares, LT.totalSupply());
        int256 leak = int256(contributed) - int256(minted);
        (int256 expectedLeak, uint256 slack) = _expectedSingleSidedAddLeak(contributed, quoteShare0, quoteSpot0, Math.mulDiv(WAD, WAD, _spotSTinQuoteWAD()));
        // The oracle basis (LT share value) undercuts the feed basis by up to the band re-mark; widen one-sided.
        (uint256 alpha,) = _stPriceBandWAD();
        slack += Math.mulDiv(contributed, WAD - alpha, WAD);
        assertApproxEqAbs(leak, expectedLeak, slack, "the in-term quote-only deposit must obey the single-sided leak law");
    }

    /**
     * @notice in-term the premium machinery is silent but the STAGED premium is not stranded: an in-term
     *         sync mints nothing, deploys nothing, and leaves the idle ledger untouched, while the permissioned
     *         manual reinvest still deploys the pre-term staged premium (a documented behavior pin: the manual
     *         path carries no term gate).
     */
    function test_FixedTerm_syncSilent_manualReinvestStillDeploysStagedPremium() public {
        uint256 idleShares = _arrangeReinvestableIdleLiquidityPremium();
        _enterFixedTerm();

        // In-term sync: no premium, no deploy, idle static.
        _warpForward(1 days);
        _applySTYield(0.01e18);
        vm.recordLogs();
        SyncedAccountingState memory state = _syncWithState();
        (uint256 reinvestCount,) = _lastLogData(vm.getRecordedLogs(), address(KERNEL), IRoycoDayKernel.LiquidityPremiumReinvested.selector);
        assertEq(reinvestCount, 0, "an in-term sync must not deploy");
        assertEq(toUint256(state.ltLiquidityPremium), 0, "an in-term sync must pay no premium");
        assertEq(KERNEL.getState().ltOwnedSeniorTrancheShares, idleShares, "the staged premium must sit untouched in-term");

        // The manual reinvest carries no term gate: the staged premium deploys in-term (behavior pin).
        assertTrue(_trySetReinvestmentSlippage(uint64(WAD - 1)), "arrange: the slippage gate must open");
        (uint256 stSharesReinvested,, uint256 eventCount) = _manualReinvestAll();
        assertEq(eventCount, 1, "the manual reinvest must deploy in-term (no term gate on the permissioned path)");
        assertEq(stSharesReinvested, idleShares, "the full staged premium must deploy");
        assertEq(KERNEL.getState().ltOwnedSeniorTrancheShares, 0, "the idle ledger must zero");
    }

    /**
     * @notice FINDING 10, companion in the inverse direction — EXTERNAL depth cannot release a binding
     *         gate: with the utilization breached, an external LP doubling the pool's REAL tradable depth
     *         changes nothing — the committed LT mark counts kernel-owned BPT only, so the LT redemption stays
     *         blocked. The venue is deep; the market says it is not.
     */
    function test_FINDING_10b_externalDepthCannotReleaseGate() public {
        _seedForSwaps();
        _arrangeYieldDrivenLiquidityBreach();
        assertGt(_committedLiquidityUtilization(), WAD, "arrange: the gate must be binding");

        _externalProportionalPosition("EXTERNAL_RESCUER_LP", _bptSupply()); // doubles the real venue depth
        _sync();

        assertGt(_committedLiquidityUtilization(), WAD, "FINDING: doubling the REAL depth does not move the committed utilization");
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 10;
        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        LT.redeem(shares, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
    }
}
