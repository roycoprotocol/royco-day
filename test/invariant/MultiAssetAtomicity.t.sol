// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVaultErrors } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { toUint256 } from "../../src/libraries/Units.sol";
import { defaultParams } from "../base/fixtures/MarketParams.sol";
import { cellA } from "../base/fixtures/TokenConfigs.sol";
import { TrancheFixture } from "../base/fixtures/TrancheFixture.sol";
import { RoycoTestMath } from "../base/math/RoycoTestMath.sol";
import { MockBalancerVault } from "../mocks/MockBalancerVault.sol";

/**
 * @title MultiAssetAtomicityTest
 * @notice The two multi-asset liquidity flows are all-or-nothing: a failure injected into any leg (the venue
 *         mint, the venue removal, a caller floor, or a post-op gate) must roll back the entire flow with no
 *         partial senior mint, no partial idle-pile debit, and no share movement, verified by comparing
 *         byte-exact digests of every market ledger before and after the failed call
 * @dev Also pins the gate post-conditions in both directions: flows the gates enforce leave utilization at or
 *      below one hundred percent when they succeed, and flows the gates exempt (pure liquidity deposits, and
 *      every redemption once liquidation coverage is breached) still succeed while the gates read breached
 */
contract MultiAssetAtomicityTest is TrancheFixture {
    /// @dev One whole quote token in its native decimals (cell A quotes at 6 decimals, so 1e6)
    uint256 internal QUOTE_UNIT;

    /**
     * @dev Seeds a healthy default market: 30,000 junior vault shares (coverage first), 100,000 senior vault
     *      shares (the fixture auto-seeds the minimal quote-only pool depth its liquidity gate needs), then
     *      real two-leg pool depth so the multi-asset flows have a senior leg to unwind: 2,000 senior shares
     *      (2,000e18 NAV at the 1.0 seed rate) against 8,000 quote tokens (8,000e18 NAV), minted as
     *      2,000e18 + 8,000e18 = 10,000e18 pool tokens so NAV-per-BPT stays exactly 1.0
     */
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        QUOTE_UNIT = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(100_000e18, 30_000e18);
        _seedLT(10_000e18, 2_000e18, 8_000 * QUOTE_UNIT);
        _sync();
    }

    // =============================
    // Snapshot machinery
    // =============================

    /**
     * @dev Byte-exact digest of every ledger a multi-asset flow can touch: the committed accounting
     *      checkpoint, the kernel's ownership ledgers (including the staged idle-premium pile), all three
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
     * @dev Stages idle liquidity-premium senior shares in the kernel: arms the venue's punitive slippage so
     *      the sync's reinvest gate fails, then realizes a 2% senior gain over a day so the premium carve-out
     *      mints senior shares that cannot deploy and must sit as the staged idle pile
     */
    function _stageIdlePremium() internal returns (uint256 idleShares) {
        setVenueSlippageMode(true);
        _warpAndRefreshFeed(1 days);
        applySTPnL(200);
        _sync();
        idleShares = kernel.getState().ltOwnedSeniorTrancheShares;
        require(idleShares != 0, "setup: expected the liquidity premium to stage as idle senior shares");
    }

    // =============================
    // Multi-asset deposit: one injected failure per leg, whole-flow rollback each time
    // =============================

    /// @notice A pool mint shorted below the caller's floor rejects the whole deposit, leaving no partial senior mint behind
    function test_multiAssetDepositRollsBackWhollyWhenTheVenueShortsTheMintedPoolTokens() public {
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
    function test_multiAssetDepositRollsBackWhollyWhenTheVenueAddReverts() public {
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
    function test_multiAssetDepositRollsBackWhollyWhenTheSeniorLegBreachesCoverage() public {
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

    /// @notice A venue removal that reverts outright rejects the whole redemption, leaving the staged idle pile untouched
    function test_multiAssetRedeemRollsBackWhollyWhenTheVenueRemovalReverts() public {
        // Stage idle premium first so a partial idle-pile debit would be visible in the digest
        _stageIdlePremium();
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
        assertEq(_marketDigest(actor), digestBefore, "a reverted multi-asset redemption left a partial trace (idle-pile debit or share burn)");

        balancerVault.setRevertMode(MockBalancerVault.RevertMode.NONE);
    }

    /// @notice A quote constituent under the caller's floor rejects the whole redemption, senior leg included
    function test_multiAssetRedeemRollsBackWhollyWhenAConstituentFallsUnderTheCallerFloor() public {
        _stageIdlePremium();
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
    function test_multiAssetRedeemRollsBackWhollyWhenItWouldPullDepthBelowTheSeniorLiquidityFloor() public {
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
    function test_successfulMultiAssetRedeemLeavesTheSeniorLiquidityFloorIntact() public {
        address actor = LT_PROVIDER;
        // The advertised maximum presses the gate to its boundary, the strongest success-side probe
        uint256 shares = liquidityTranche.maxRedeem(actor);
        require(shares != 0, "setup: expected redeemable liquidity shares");

        vm.prank(actor);
        liquidityTranche.redeemMultiAsset(shares, 0, 0, actor, actor);

        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        uint256 utilization = RoycoTestMath.liqUtil(toUint256(a.lastSTEffectiveNAV), a.minLiquidityWAD, toUint256(a.lastLTRawNAV));
        assertLe(utilization, WAD, "an enforced redemption left the market short of its senior liquidity floor");
    }

    /// @notice Depositing the production-advertised senior maximum lands both gates at or below one hundred percent
    function test_successfulMultiAssetDepositLeavesCoverageAndLiquidityWithinTheirLimits() public {
        address actor = LT_PROVIDER;
        // The advertised senior capacity presses the coverage gate to its boundary
        uint256 stAssets = toUint256(kernel.stMaxDeposit(actor));
        require(stAssets != 0, "setup: expected senior deposit capacity");
        uint256 quoteAssets = 100 * QUOTE_UNIT;
        _fundDepositLegs(actor, stAssets, quoteAssets);

        vm.prank(actor);
        liquidityTranche.depositMultiAsset(stAssets, quoteAssets, 0, actor);

        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        uint256 coverage = RoycoTestMath.covUtil(
            toUint256(a.lastSTRawNAV), toUint256(a.lastJTRawNAV), accountant.JT_COINVESTED(), a.minCoverageWAD, toUint256(a.lastJTEffectiveNAV)
        );
        uint256 liquidity = RoycoTestMath.liqUtil(toUint256(a.lastSTEffectiveNAV), a.minLiquidityWAD, toUint256(a.lastLTRawNAV));
        assertLe(coverage, WAD, "an enforced deposit left coverage utilization above one hundred percent");
        assertLe(liquidity, WAD, "an enforced deposit left liquidity utilization above one hundred percent");
    }

    // =============================
    // Gate post-conditions, exemption direction: exempt flows still succeed in breach states
    // =============================

    /// @notice Liquidity deposits stay open while the market is short of its senior liquidity floor, and they restore it
    function test_depositsStillSucceedWhileTheMarketIsBelowItsSeniorLiquidityFloor() public {
        // Crash the pool's quote leg 90% in both price stores: the pool mark collapses while senior NAV is
        // untouched, so liquidity utilization breaches one hundred percent with no operation involved
        applyLTPnL(-9000);
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        uint256 utilizationBefore = RoycoTestMath.liqUtil(toUint256(a.lastSTEffectiveNAV), a.minLiquidityWAD, toUint256(a.lastLTRawNAV));
        assertGt(utilizationBefore, WAD, "setup: expected the senior liquidity floor to read breached");

        // A quote-only multi-asset deposit (no senior leg, so no senior gates) must land in the breach state
        address actor = LT_PROVIDER;
        uint256 quoteAssets = 500 * QUOTE_UNIT;
        _fundDepositLegs(actor, 0, quoteAssets);
        vm.prank(actor);
        liquidityTranche.depositMultiAsset(0, quoteAssets, 0, actor);

        // The deposit is the restoring force: it must have pulled utilization back down
        _sync();
        a = accountant.getState();
        uint256 utilizationAfter = RoycoTestMath.liqUtil(toUint256(a.lastSTEffectiveNAV), a.minLiquidityWAD, toUint256(a.lastLTRawNAV));
        assertLt(utilizationAfter, utilizationBefore, "a liquidity deposit in a breach state must reduce liquidity utilization");
    }

    /// @notice Once liquidation coverage is breached the liquidity gate stands down and a full exit succeeds, unwinding the whole idle pile
    function test_liquidityFloorGateStandsDownOnceLiquidationCoverageIsBreached() public {
        // Idle premium rides along so the exempt redemption also proves the full idle-pile unwind
        uint256 idleBefore = _stageIdlePremium();

        // Crash the shared senior/junior rate 60%: junior absorbs losses until exhausted, so coverage
        // utilization reads infinite, past every liquidation threshold, and the market forces perpetual
        applySTPnL(-6000);
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        uint256 coverage = RoycoTestMath.covUtil(
            toUint256(a.lastSTRawNAV), toUint256(a.lastJTRawNAV), accountant.JT_COINVESTED(), a.minCoverageWAD, toUint256(a.lastJTEffectiveNAV)
        );
        assertGe(coverage, a.coverageLiquidationUtilizationWAD, "setup: expected liquidation coverage to read breached");

        // The provider's near-total exit would leave the pool below the senior liquidity floor, yet it must
        // succeed because the wind-down exemption bypasses the liquidity gate. The provider no longer owns
        // the WHOLE supply: paying the premium also minted a protocol-fee slice of liquidity shares to the
        // fee recipient, so the exit unwinds the provider's pro-rata idle slice, not the entire pile
        address actor = LT_PROVIDER;
        uint256 supply = liquidityTranche.totalSupply();
        uint256 shares = liquidityTranche.balanceOf(actor);
        uint256 expectedIdleAfter = idleBefore - Math.mulDiv(idleBefore, shares, supply);
        vm.prank(actor);
        liquidityTranche.redeemMultiAsset(shares, 0, 0, actor, actor);

        // The exit must debit exactly its pro-rata idle slice: idleBefore - floor(idleBefore * shares / supply)
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, expectedIdleAfter, "the exit's idle-pile debit diverges from its pro-rata slice");

        // Prove the exemption was load-bearing: the post-exit market is genuinely short of its liquidity floor
        _sync();
        a = accountant.getState();
        uint256 utilization = RoycoTestMath.liqUtil(toUint256(a.lastSTEffectiveNAV), a.minLiquidityWAD, toUint256(a.lastLTRawNAV));
        assertGt(utilization, WAD, "the bypassed gate should read breached after the full exit, proving the exemption mattered");
    }
}
