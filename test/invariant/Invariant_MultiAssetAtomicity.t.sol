// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVaultErrors } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoLiquidityTranche } from "../../src/interfaces/IRoycoLiquidityTranche.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { AssetClaims } from "../../src/libraries/Types.sol";
import { toUint256 } from "../../src/libraries/Units.sol";
import { defaultParams } from "../utils/MarketParams.sol";
import { cellA } from "../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../utils/DayMarketTestBase.sol";
import { RoycoTestMath } from "../utils/RoycoTestMath.sol";
import { MockBalancerVault } from "../mocks/MockBalancerVault.sol";

/**
 * @title Invariant_MultiAssetAtomicity
 * @notice The two multi-asset liquidity flows are all-or-nothing: a failure injected into any leg (the venue
 *         mint, the venue removal, a caller floor, or a post-op gate) must roll back the entire flow with no
 *         partial senior mint, no partial debit of the idle liquidity premium senior shares, and no share
 *         movement, verified by comparing byte-exact digests of every market ledger before and after the
 *         failed call
 * @dev Also pins the gate post-conditions in both directions: flows the gates enforce leave utilization at or
 *      below one hundred percent when they succeed, and flows the gates exempt (pure liquidity deposits, and
 *      every redemption once liquidation coverage is breached) still succeed while the gates read breached
 */
contract Invariant_MultiAssetAtomicity is DayMarketTestBase {
    /// @dev One whole quote token in its native decimals (this market's quote asset uses 6 decimals, so 1e6)
    uint256 internal QUOTE_UNIT;

    /**
     * @dev Seeds a healthy default market: 30,000 junior vault shares (coverage first), 100,000 senior vault
     *      shares (the market base auto-seeds the minimal quote-only pool depth its liquidity gate needs),
     *      then real two-leg pool depth so the multi-asset flows have a senior leg to unwind: 2,000 senior
     *      shares (2,000e18 NAV at the 1.0 seed rate) against 8,000 quote tokens (8,000e18 NAV), minted as
     *      2,000e18 + 8,000e18 = 10,000e18 pool tokens so NAV-per-BPT stays exactly 1.0
     */
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        QUOTE_UNIT = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(100_000e18, 30_000e18);
        _seedLT(10_000e18, 2000e18, 8000 * QUOTE_UNIT);
        _sync();
    }

    // =============================
    // Snapshot machinery
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

    /// @dev Funds and approves the actor's two deposit legs so the only thing left to fail is the flow itself
    function _fundDepositLegs(address _actor, uint256 _stAssets, uint256 _quoteAssets) internal {
        stJtVault.mintShares(_actor, _stAssets);
        quoteToken.mint(_actor, _quoteAssets);
        vm.startPrank(_actor);
        stJtVault.approve(address(liquidityTranche), _stAssets);
        quoteToken.approve(address(liquidityTranche), _quoteAssets);
        vm.stopPrank();
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
    // Multi-asset deposit: one injected failure per leg, whole-flow rollback each time
    // =============================

    /// @notice A pool mint shorted below the caller's floor rejects the whole deposit, leaving no partial senior mint behind
    function test_LTDepositMultiAsset_VenueShortsMintedPoolTokens_RollsBackWholly() public {
        address actor = LT_PROVIDER;
        // 100 senior vault shares (100e18 NAV at the current rate) against 100 quote tokens (100e18 NAV)
        uint256 stAssets = 100e18;
        uint256 quoteAssets = 100 * QUOTE_UNIT;
        _fundDepositLegs(actor, stAssets, quoteAssets);

        // Arm the venue to mint a single BPT wei while the caller demands at least half the roughly
        // 200e18 fair value of the two legs, so the venue's own floor check must throw
        balancerVault.setNextBptOutOverride(1);
        uint256 minLtAssetsOut = 100e18;

        bytes32 digestBefore = _marketDigest(actor);
        vm.prank(actor);
        try liquidityTranche.depositMultiAsset(stAssets, quoteAssets, minLtAssetsOut, actor) returns (uint256) {
            fail("the deposit must revert when the venue mints fewer pool tokens than the caller's floor");
        } catch (bytes memory err) {
            assertEq(bytes4(err), IVaultErrors.BptAmountOutBelowMin.selector, "expected the venue's shorted-mint floor error");
        }
        assertEq(_marketDigest(actor), digestBefore, "a reverted multi-asset deposit left a partial trace on the market");

        // The revert rolled the one-shot override back to armed, so disarm it explicitly
        balancerVault.clearNextBptOutOverride();
    }

    /// @notice A venue add that reverts outright rejects the whole deposit, leaving no partial senior mint behind
    function test_LTDepositMultiAsset_VenueAddReverts_RollsBackWholly() public {
        address actor = LT_PROVIDER;
        // 100 senior vault shares against 100 quote tokens, both fully funded, only the venue fails
        uint256 stAssets = 100e18;
        uint256 quoteAssets = 100 * QUOTE_UNIT;
        _fundDepositLegs(actor, stAssets, quoteAssets);
        balancerVault.setRevertMode(MockBalancerVault.RevertMode.ADD);

        bytes32 digestBefore = _marketDigest(actor);
        vm.prank(actor);
        try liquidityTranche.depositMultiAsset(stAssets, quoteAssets, 0, actor) returns (uint256) {
            fail("the deposit must revert when the venue add reverts");
        } catch (bytes memory err) {
            assertEq(bytes4(err), MockBalancerVault.FORCED_ADD_REVERT.selector, "the venue's revert must bubble out of the whole flow");
        }
        assertEq(_marketDigest(actor), digestBefore, "a reverted multi-asset deposit left a partial trace on the market");

        balancerVault.setRevertMode(MockBalancerVault.RevertMode.NONE);
    }

    /// @notice A senior leg past the coverage capacity rejects the whole deposit through the post-op gate, quote leg included
    function test_LTDepositMultiAsset_SeniorLegBreachesCoverage_RollsBackWholly() public {
        address actor = LT_PROVIDER;
        // The advertised senior capacity plus 10,000 whole vault shares of clear overshoot, so the post-op
        // coverage check must reject regardless of dust slack
        uint256 stAssets = toUint256(kernel.stMaxDeposit(actor)) + 10_000e18;
        uint256 quoteAssets = 100 * QUOTE_UNIT;
        _fundDepositLegs(actor, stAssets, quoteAssets);

        bytes32 digestBefore = _marketDigest(actor);
        vm.prank(actor);
        try liquidityTranche.depositMultiAsset(stAssets, quoteAssets, 0, actor) returns (uint256) {
            fail("the deposit must revert when its senior leg exceeds the market's coverage capacity");
        } catch (bytes memory err) {
            assertEq(bytes4(err), IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector, "expected the coverage gate to reject the whole flow");
        }
        assertEq(_marketDigest(actor), digestBefore, "a gate-rejected multi-asset deposit left a partial trace on the market");
    }

    // =============================
    // Multi-asset redemption: one injected failure per leg, whole-flow rollback each time
    // =============================

    /// @notice A venue removal that reverts outright rejects the whole redemption, leaving ltOwnedSeniorTrancheShares untouched
    function test_LTRedeemMultiAsset_VenueRemovalReverts_RollsBackWholly() public {
        // Accumulate idle liquidity premium senior shares first so a partial debit would be visible in the digest
        _accumulateIdleLiquidityPremiumSeniorShares();
        address actor = LT_PROVIDER;
        // A quarter exit, comfortably above the senior liquidity floor, so only the venue fails
        uint256 shares = liquidityTranche.balanceOf(actor) / 4;
        balancerVault.setRevertMode(MockBalancerVault.RevertMode.REMOVE);

        bytes32 digestBefore = _marketDigest(actor);
        vm.prank(actor);
        try liquidityTranche.redeemMultiAsset(shares, 0, 0, actor, actor) {
            fail("the redemption must revert when the venue removal reverts");
        } catch (bytes memory err) {
            assertEq(bytes4(err), MockBalancerVault.FORCED_REMOVE_REVERT.selector, "the venue's revert must bubble out of the whole flow");
        }
        assertEq(_marketDigest(actor), digestBefore, "a reverted multi-asset redemption left a partial trace (idle senior share debit or share burn)");

        balancerVault.setRevertMode(MockBalancerVault.RevertMode.NONE);
    }

    /// @notice A quote constituent under the caller's floor rejects the whole redemption, senior leg included
    function test_LTRedeemMultiAsset_QuoteOutBelowCallerFloor_RollsBackWholly() public {
        _accumulateIdleLiquidityPremiumSeniorShares();
        address actor = LT_PROVIDER;
        uint256 shares = liquidityTranche.balanceOf(actor) / 4;
        // The whole pool holds on the order of 13,000 quote tokens, so demanding 1,000,000 out must trip the floor
        uint256 minQuoteAssetsOut = 1_000_000 * QUOTE_UNIT;

        bytes32 digestBefore = _marketDigest(actor);
        vm.prank(actor);
        try liquidityTranche.redeemMultiAsset(shares, 0, minQuoteAssetsOut, actor, actor) {
            fail("the redemption must revert when a constituent falls under the caller's floor");
        } catch (bytes memory err) {
            assertEq(bytes4(err), IVaultErrors.AmountOutBelowMin.selector, "expected the venue's constituent floor error");
        }
        assertEq(_marketDigest(actor), digestBefore, "a floor-rejected multi-asset redemption left a partial trace on the market");
    }

    /// @notice A redemption that would pull pool depth below the senior liquidity floor is rejected whole by the post-op gate
    function test_LTRedeemMultiAsset_WouldBreachLiquidityFloor_RollsBackWholly() public {
        address actor = LT_PROVIDER;
        // The provider owns every liquidity share, so a full exit would empty the pool the senior floor requires
        uint256 shares = liquidityTranche.balanceOf(actor);
        assertEq(shares, liquidityTranche.totalSupply(), "setup: the provider is expected to own the whole liquidity supply");

        bytes32 digestBefore = _marketDigest(actor);
        vm.prank(actor);
        try liquidityTranche.redeemMultiAsset(shares, 0, 0, actor, actor) {
            fail("the redemption must revert when it would pull depth below the senior liquidity floor");
        } catch (bytes memory err) {
            assertEq(bytes4(err), IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector, "expected the liquidity gate to reject the whole flow");
        }
        assertEq(_marketDigest(actor), digestBefore, "a gate-rejected multi-asset redemption left a partial trace on the market");
    }

    // =============================
    // Gate post-conditions, success direction: enforced flows land at or below one hundred percent
    // =============================

    /// @notice Redeeming the production-advertised maximum lands liquidity utilization at or below one hundred percent
    function test_LTRedeemMultiAsset_MaxRedeem_LeavesLiquidityUtilizationAtOrBelowWAD() public {
        address actor = LT_PROVIDER;
        // The advertised maximum presses the gate to its boundary, the strongest success-side probe
        uint256 shares = liquidityTranche.maxRedeem(actor);
        require(shares != 0, "setup: expected redeemable liquidity shares");

        // The money path must announce itself: MultiAssetRedeem with this caller, receiver, and owner
        // (the claim legs are venue-priced and pinned wei-exact by the preview-parity suite)
        AssetClaims memory uncheckedClaims;
        vm.expectEmit(true, true, true, false, address(liquidityTranche));
        emit IRoycoLiquidityTranche.MultiAssetRedeem(actor, actor, actor, shares, uncheckedClaims, 0);
        vm.prank(actor);
        liquidityTranche.redeemMultiAsset(shares, 0, 0, actor, actor);

        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        uint256 liquidityUtilizationWAD =
            RoycoTestMath.computeLiquidityUtilization(toUint256(a.lastSTEffectiveNAV), a.minLiquidityWAD, toUint256(a.lastLTRawNAV));
        assertLe(liquidityUtilizationWAD, WAD, "an enforced redemption left the market short of its senior liquidity floor");
    }

    /**
     * @notice The attacker's boundary-parking probe: after the advertised maximum exit parks the market at
     *         the liquidity gate's boundary, a one-share follow-up must either be rejected by the gate (or
     *         round to a no-op) or still leave liquidity utilization at or below one hundred percent. The
     *         floor can never be broken by splitting an exit around the advertised maximum
     */
    function test_LTRedeemMultiAsset_OneShareProbePastMaxRedeem_CannotBreachLiquidityFloor() public {
        address actor = LT_PROVIDER;
        uint256 maxShares = liquidityTranche.maxRedeem(actor);
        require(maxShares != 0, "setup: expected redeemable liquidity shares");
        require(liquidityTranche.balanceOf(actor) > maxShares, "setup: expected the gate (not the balance) to bind the maximum");

        vm.prank(actor);
        liquidityTranche.redeemMultiAsset(maxShares, 0, 0, actor, actor);

        // The probe past the boundary: one more share through the same gated flow
        vm.prank(actor);
        try liquidityTranche.redeemMultiAsset(1, 0, 0, actor, actor) {
            // The gate let it through, so it must have been utilization-neutral at the committed marks
            _sync();
            IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
            uint256 liquidityUtilizationWAD =
                RoycoTestMath.computeLiquidityUtilization(toUint256(a.lastSTEffectiveNAV), a.minLiquidityWAD, toUint256(a.lastLTRawNAV));
            assertLe(liquidityUtilizationWAD, WAD, "a one-share redemption past the advertised maximum broke the senior liquidity floor");
        } catch (bytes memory err) {
            // Otherwise only the liquidity gate (or the one-share rounding to a valueless op) may reject it
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector || sel == IRoycoDayAccountant.INVALID_POST_OP_STATE.selector,
                "the boundary probe was rejected by something other than the liquidity gate or the valueless-op check"
            );
        }
    }

    /// @notice Depositing the production-advertised senior maximum lands both gates at or below one hundred percent
    function test_LTDepositMultiAsset_MaxSeniorLeg_LeavesBothUtilizationsAtOrBelowWAD() public {
        address actor = LT_PROVIDER;
        // The advertised senior capacity presses the coverage gate to its boundary
        uint256 stAssets = toUint256(kernel.stMaxDeposit(actor));
        require(stAssets != 0, "setup: expected senior deposit capacity");
        uint256 quoteAssets = 100 * QUOTE_UNIT;
        _fundDepositLegs(actor, stAssets, quoteAssets);

        // The money path must announce itself: MultiAssetDeposit with this caller and receiver
        // (the minted-amount legs are venue-priced and pinned wei-exact by the preview-parity suite)
        vm.expectEmit(true, true, true, false, address(liquidityTranche));
        emit IRoycoLiquidityTranche.MultiAssetDeposit(actor, actor, stAssets, quoteAssets, 0, 0);
        vm.prank(actor);
        liquidityTranche.depositMultiAsset(stAssets, quoteAssets, 0, actor);

        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        uint256 coverageUtilizationWAD = RoycoTestMath.computeCoverageUtilization(
            toUint256(a.lastSTRawNAV), toUint256(a.lastJTRawNAV), accountant.JT_COINVESTED(), a.minCoverageWAD, toUint256(a.lastJTEffectiveNAV)
        );
        uint256 liquidityUtilizationWAD =
            RoycoTestMath.computeLiquidityUtilization(toUint256(a.lastSTEffectiveNAV), a.minLiquidityWAD, toUint256(a.lastLTRawNAV));
        assertLe(coverageUtilizationWAD, WAD, "an enforced deposit left coverage utilization above one hundred percent");
        assertLe(liquidityUtilizationWAD, WAD, "an enforced deposit left liquidity utilization above one hundred percent");
    }

    // =============================
    // Gate post-conditions, exemption direction: exempt flows still succeed in breach states
    // =============================

    /// @notice Liquidity deposits stay open while the market is short of its senior liquidity floor, and they restore it
    function test_LTDepositMultiAsset_LiquidityFloorBreached_DepositStillSucceedsAndRestores() public {
        // Crash the pool's quote leg 90% in both price stores: the pool mark collapses while senior NAV is
        // untouched, so liquidity utilization breaches one hundred percent with no operation involved
        applyLTPnL(-9000);
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        uint256 liquidityUtilizationBefore =
            RoycoTestMath.computeLiquidityUtilization(toUint256(a.lastSTEffectiveNAV), a.minLiquidityWAD, toUint256(a.lastLTRawNAV));
        assertGt(liquidityUtilizationBefore, WAD, "setup: expected the senior liquidity floor to read breached");

        // A quote-only multi-asset deposit (no senior leg, so no senior gates) must land in the breach state
        address actor = LT_PROVIDER;
        uint256 quoteAssets = 500 * QUOTE_UNIT;
        _fundDepositLegs(actor, 0, quoteAssets);
        vm.prank(actor);
        liquidityTranche.depositMultiAsset(0, quoteAssets, 0, actor);

        // The deposit is the restoring force: it must have pulled utilization back down
        _sync();
        a = accountant.getState();
        uint256 liquidityUtilizationAfter =
            RoycoTestMath.computeLiquidityUtilization(toUint256(a.lastSTEffectiveNAV), a.minLiquidityWAD, toUint256(a.lastLTRawNAV));
        assertLt(liquidityUtilizationAfter, liquidityUtilizationBefore, "a liquidity deposit in a breach state must reduce liquidity utilization");
    }

    /// @notice Once liquidation coverage is breached the liquidity gate stands down and a full exit succeeds,
    ///         unwinding the redeemer's slice of the idle liquidity premium senior shares
    function test_LTRedeemMultiAsset_LiquidationCoverageBreached_LiquidityGateStandsDown() public {
        // Idle liquidity premium senior shares ride along so the exempt redemption also proves their unwind
        uint256 idleBefore = _accumulateIdleLiquidityPremiumSeniorShares();

        // Crash the shared senior/junior rate 60%: junior absorbs losses until exhausted, so coverage
        // utilization reads infinite, past every liquidation threshold, and the market forces perpetual
        applySTPnL(-6000);
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        uint256 coverageUtilizationWAD = RoycoTestMath.computeCoverageUtilization(
            toUint256(a.lastSTRawNAV), toUint256(a.lastJTRawNAV), accountant.JT_COINVESTED(), a.minCoverageWAD, toUint256(a.lastJTEffectiveNAV)
        );
        assertGe(coverageUtilizationWAD, a.coverageLiquidationUtilizationWAD, "setup: expected liquidation coverage to read breached");

        // The provider's near-total exit would leave the pool below the senior liquidity floor, yet it must
        // succeed because the wind-down exemption bypasses the liquidity gate. The provider no longer owns
        // the WHOLE supply: paying the premium also minted a protocol-fee slice of liquidity shares to the
        // fee recipient, so the exit unwinds the provider's pro-rata slice of the idle senior shares, not all of them
        address actor = LT_PROVIDER;
        uint256 supply = liquidityTranche.totalSupply();
        uint256 shares = liquidityTranche.balanceOf(actor);
        uint256 expectedIdleAfter = idleBefore - Math.mulDiv(idleBefore, shares, supply);
        vm.prank(actor);
        liquidityTranche.redeemMultiAsset(shares, 0, 0, actor, actor);

        // The exit must debit exactly its pro-rata idle slice: idleBefore - floor(idleBefore * shares / supply)
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, expectedIdleAfter, "the exit's idle senior share debit diverges from its pro-rata slice");

        // Prove the exemption was load-bearing: the post-exit market is genuinely short of its liquidity floor
        _sync();
        a = accountant.getState();
        uint256 liquidityUtilizationWAD =
            RoycoTestMath.computeLiquidityUtilization(toUint256(a.lastSTEffectiveNAV), a.minLiquidityWAD, toUint256(a.lastLTRawNAV));
        assertGt(liquidityUtilizationWAD, WAD, "the bypassed gate should read breached after the full exit, proving the exemption mattered");
    }
}
