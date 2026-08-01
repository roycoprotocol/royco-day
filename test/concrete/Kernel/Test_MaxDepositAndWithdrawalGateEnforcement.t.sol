// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MarketFuzzTestBase } from "../../utils/MarketFuzzTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title Test_MaxDepositAndWithdrawalGateEnforcement_Kernel
 * @notice The re-homed negative (one wei / one share past the reported max reverts) halves of the accountant's
 *         gate-boundary probes in test/concrete/Accountant/Test_MaxDepositAndWithdrawal.t.sol, driven through the
 *         full production stack (tranche -> real kernel -> accountant) so the revert fires against the real gate
 * @dev The enforcement moved out of the accountant and into the kernel (AccountingSyncLogic._postOpSyncTrancheAccounting
 *      errors on IRoycoDayKernel), so the accountant suite's MockAccountantKernel passthrough can no longer observe
 *      the revert. These concrete seeds mirror each boundary scenario the accountant suite keeps the positive half
 *      of: the two ST-deposit legs (coverage and liquidity binding), their dust-slack variants, the JT-redemption
 *      coverage boundary on a divisible and a non-divisible required value, and the LPT-redemption liquidity
 *      boundary at zero and a live dust tolerance. TestFuzz_MaxDepositAndWithdrawal_Kernel sweeps the same three
 *      gates over 9 orders of magnitude, these pin the exact concrete boundaries the accountant probes advertise
 * @dev Flat 1.0 vault rate and 1.0 prices throughout, so one vault-share wei == one BPT wei == one NAV wei on the
 *      seed. Default params bind minCoverage 0.2e18 and minLiquidity 0.05e18 (both divide WAD, so the gate
 *      boundaries stay exact integer algebra), with the dust variants redeploying at a 1e12 collateral NAV dust
 */
contract Test_MaxDepositAndWithdrawalGateEnforcement_Kernel is MarketFuzzTestBase {
    /*//////////////////////////////////////////////////////////////////////
                        maxSTDeposit REAL-KERNEL GATE BOUNDARIES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Re-homes the coverage-binding negative half (accountant test_MaxSTDeposit_CoverageBindingExactGateBoundary).
     * Deep pool leaves liquidity slack so coverage binds: covBound = 4*jt - st = 600e18 sits far below
     * liqBound = 20*depth - st. Filling the reported max then the single dust wei lands coverage utilization on WAD,
     * and one more wei violates the coverage requirement on the real kernel
     */
    function test_STDeposit_CoverageBindingGate_OneWeiPastMaxReverts() public {
        uint256 st = 1000e18;
        uint256 jt = 400e18;
        uint256 depth = _seedFlatMarket(st, jt, 2e8); // ~201e18 of depth so the liquidity leg stays slack
        uint256 dust = params.dustTolerance;

        uint256 covBound = 4 * jt - st;
        uint256 liqBound = 20 * depth - st;
        assertLt(covBound, liqBound, "the deep pool must leave coverage the binding leg");

        uint256 reportedMax = toUint256(seniorTranche.maxDeposit(ST_PROVIDER));
        assertEq(reportedMax, covBound - dust, "reported max is the coverage boundary minus the dust slack");

        // Fill the reported max then consume the dust slack, landing exactly on the algebraic boundary
        _depositSenior(reportedMax);
        _depositSenior(dust);
        assertEq(toUint256(accountant.getState().lastCollateralNAV), st + jt + covBound, "the slack deposit lands on the coverage boundary");

        // One wei past the boundary violates the coverage requirement on the real kernel
        _expectSeniorDepositReverts(IRoycoDayKernel.COVERAGE_REQUIREMENT_VIOLATED.selector);
    }

    /**
     * Re-homes the liquidity-binding negative half (accountant test_MaxSTDeposit_LiquidityBindingExactGateBoundary).
     * Shallow auto-seeded pool makes liquidity bind: liqBound = 20*depth - st sits far below covBound = 4*jt - st.
     * The reported max plus the dust wei lands liquidity utilization on WAD, and one more wei violates liquidity
     */
    function test_STDeposit_LiquidityBindingGate_OneWeiPastMaxReverts() public {
        uint256 st = 1000e18;
        uint256 jt = 1000e18;
        uint256 depth = _seedFlatMarket(st, jt, 0); // only the auto-seeded minimal depth, so liquidity binds tight
        uint256 dust = params.dustTolerance;

        uint256 covBound = 4 * jt - st;
        uint256 liqBound = 20 * depth - st;
        assertLt(liqBound, covBound, "the shallow pool must leave liquidity the binding leg");

        uint256 reportedMax = toUint256(seniorTranche.maxDeposit(ST_PROVIDER));
        assertEq(reportedMax, liqBound - dust, "reported max is the liquidity boundary minus the dust slack");

        _depositSenior(reportedMax);
        _depositSenior(dust);
        assertEq(toUint256(accountant.getState().lastCollateralNAV), st + jt + liqBound, "the slack deposit lands on the liquidity boundary");

        // One wei past the boundary violates the liquidity requirement on the real kernel
        _expectSeniorDepositReverts(IRoycoDayKernel.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
    }

    /**
     * Re-homes the coverage dust-slack negative half (accountant test_MaxSTDeposit_DustSlackExactGateBoundary).
     * At a 1e12 collateral NAV dust the reported max under-shoots the coverage boundary by exactly the dust, so
     * the max deposit passes, consuming the dust slack lands coverage utilization on WAD, and one more wei violates
     */
    function test_STDeposit_CoverageDustSlackGate_ConsumesSlackThenReverts() public {
        // Raise the live market's dust tolerance in place: redeploying just for a param would re-roll the
        // tranche/quote address ordering the venue's structural token check pins (the factory mines it in prod)
        vm.prank(MARKET_OPS_ADMIN);
        accountant.setDustTolerance(toNAVUnits(uint256(1e12)));

        uint256 st = 1000e18;
        uint256 jt = 400e18;
        _seedFlatMarket(st, jt, 2e8); // coverage binds, plenty of liquidity depth
        uint256 dust = 1e12;

        uint256 covBound = 4 * jt - st;
        uint256 reportedMax = toUint256(seniorTranche.maxDeposit(ST_PROVIDER));
        assertEq(reportedMax, covBound - dust, "reported max holds back exactly the dust slack");

        _depositSenior(reportedMax);
        _depositSenior(dust);
        assertEq(toUint256(accountant.getState().lastCollateralNAV), st + jt + covBound, "the slack consumed lands on the coverage boundary");

        _expectSeniorDepositReverts(IRoycoDayKernel.COVERAGE_REQUIREMENT_VIOLATED.selector);
    }

    /**
     * Re-homes the liquidity dust-slack negative half
     * (accountant test_MaxSTDeposit_LiquidityBindingWithDustSlackGateBoundary). At a 1e12 dust the reported max
     * under-shoots the liquidity boundary by exactly the dust, the slack consumed lands liquidity utilization on
     * WAD, and one more wei violates liquidity
     */
    function test_STDeposit_LiquidityDustSlackGate_ConsumesSlackThenReverts() public {
        // In-place dust raise, same rationale as the coverage dust-slack seed above
        vm.prank(MARKET_OPS_ADMIN);
        accountant.setDustTolerance(toNAVUnits(uint256(1e12)));

        uint256 st = 1000e18;
        uint256 jt = 1000e18;
        uint256 depth = _seedFlatMarket(st, jt, 0); // shallow pool so liquidity binds
        uint256 dust = 1e12;

        uint256 liqBound = 20 * depth - st;
        uint256 reportedMax = toUint256(seniorTranche.maxDeposit(ST_PROVIDER));
        assertEq(reportedMax, liqBound - dust, "reported max holds back exactly the dust slack");

        _depositSenior(reportedMax);
        _depositSenior(dust);
        assertEq(toUint256(accountant.getState().lastCollateralNAV), st + jt + liqBound, "the slack consumed lands on the liquidity boundary");

        _expectSeniorDepositReverts(IRoycoDayKernel.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
    }

    /*//////////////////////////////////////////////////////////////////////
                        maxJTWithdrawal REAL-KERNEL GATE BOUNDARIES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Re-homes the flat-market JT coverage negative half (accountant test_MaxJTWithdrawal_FlatMarketExactGateBoundary,
     * with the non-flat seed's tight-to-the-wei bound covered by the same enforcement). Redeeming the largest
     * gate-respecting share count sStar succeeds, and one share past it withdraws boundary + 1 NAV and violates coverage.
     * boundaryNAV = floor((4*jt - st)/4) = 150e18 divides exactly here
     */
    function test_JTRedemption_CoverageGate_OneSharePastMaxReverts() public {
        uint256 st = 1000e18;
        uint256 jt = 400e18;
        _seedFlatMarket(st, jt, 0);

        uint256 boundaryNAV = (4 * jt - st) / 4; // 150e18 divides exactly
        uint256 sStar = _assertRedeemGateEnforced(IRoycoVaultTranche(address(juniorTranche)), JT_PROVIDER, IRoycoDayKernel.COVERAGE_REQUIREMENT_VIOLATED.selector);

        // The redeemed max held coverage at or below 100% and never withdrew past the algebraic coverage boundary
        uint256 jtEffAfter = toUint256(accountant.getState().lastJTEffectiveNAV);
        assertLe(jt - jtEffAfter, boundaryNAV, "the max redemption's withdrawn NAV must respect the coverage boundary");
        assertLe(
            RoycoTestMath.computeCoverageUtilization(toUint256(accountant.getState().lastCollateralNAV), 0.2e18, jtEffAfter),
            WAD,
            "coverage utilization must hold at or below 100% after the max redemption"
        );
        assertLe(sStar, jt, "the coverage boundary share count stays within the junior supply");
    }

    /**
     * Re-homes the ceil'd-required JT coverage negative half (accountant test_MaxJTWithdrawal_CeilRequiredGateBoundary
     * and test_MaxJTWithdrawal_NonFlatSeedExactGateBoundary). A non-divisible boundaryNAV = floor((4*jt - st)/4)
     * exercises the requirement ceil, and the true share boundary sStar is still tight to the share on the real kernel
     */
    function test_JTRedemption_CeilRequiredCoverageGate_OneSharePastMaxReverts() public {
        uint256 st = 1000e18 + 7;
        uint256 jt = 350e18;
        _seedFlatMarket(st, jt, 0);

        uint256 boundaryNAV = (4 * jt - st) / 4; // (400e18 - 7)/4 = 99999999999999999998, non-divisible
        _assertRedeemGateEnforced(IRoycoVaultTranche(address(juniorTranche)), JT_PROVIDER, IRoycoDayKernel.COVERAGE_REQUIREMENT_VIOLATED.selector);

        uint256 jtEffAfter = toUint256(accountant.getState().lastJTEffectiveNAV);
        assertLe(jt - jtEffAfter, boundaryNAV, "the max redemption's withdrawn NAV must respect the ceil'd coverage boundary");
        assertLe(
            RoycoTestMath.computeCoverageUtilization(toUint256(accountant.getState().lastCollateralNAV), 0.2e18, jtEffAfter),
            WAD,
            "coverage utilization must hold at or below 100% after the max redemption"
        );
    }

    /*//////////////////////////////////////////////////////////////////////
                        maxLPTWithdrawal REAL-KERNEL GATE BOUNDARIES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * Re-homes the exact LPT liquidity negative half (accountant test_MaxLPTWithdrawal_ExactGateBoundary). Redeeming
     * the largest gate-respecting share count sStar drains the pool to the required liquidity floor ceil(st/20), and
     * one share past it drops below the floor and violates liquidity on the real kernel
     */
    function test_LPTRedemption_LiquidityGate_OneSharePastMaxReverts() public {
        uint256 st = 1000e18;
        uint256 jt = 1000e18;
        _seedFlatMarket(st, jt, 1e8); // extra surplus depth so the withdrawable band is wide
        _assertLPTLiquidityGateEnforced(st);
    }

    /**
     * Re-homes the LPT dust-slack liquidity negative half (accountant test_MaxLPTWithdrawal_DustSlackGateBoundary).
     * At a 1e12 dust the reported advisory max reads more conservatively (the dust folds into the senior NAV before
     * the requirement scaling), but the real liquidity gate boundary is unchanged, so the reported max never
     * advertises past it and one share past the true boundary still violates liquidity
     */
    function test_LPTRedemption_DustSlackLiquidityGate_OneSharePastMaxReverts() public {
        // In-place dust raise, same rationale as the ST dust-slack seeds above
        vm.prank(MARKET_OPS_ADMIN);
        accountant.setDustTolerance(toNAVUnits(uint256(1e12)));

        uint256 st = 1000e18;
        uint256 jt = 1000e18;
        _seedFlatMarket(st, jt, 1e8);
        _assertLPTLiquidityGateEnforced(st);
    }

    /*//////////////////////////////////////////////////////////////////////
                                SHARED ENFORCEMENT DRIVERS
    //////////////////////////////////////////////////////////////////////*/

    /// @dev Mints one senior deposit wei to ST_PROVIDER and asserts the real kernel reverts the deposit on the given gate
    function _expectSeniorDepositReverts(bytes4 _error) internal {
        stJtVault.mintShares(ST_PROVIDER, 1);
        vm.prank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), 1);
        vm.expectRevert(_error);
        vm.prank(ST_PROVIDER);
        seniorTranche.deposit(toTrancheUnits(uint256(1)), ST_PROVIDER);
    }

    /// @dev LPT post-state gate check reused by the zero-dust and dusted liquidity boundary tests
    function _assertLPTLiquidityGateEnforced(uint256 _st) internal {
        uint256 requiredFloor = (_st + 19) / 20; // ceil(st * 0.05e18 / WAD)
        _assertRedeemGateEnforced(IRoycoVaultTranche(address(liquidityProviderTranche)), LPT_PROVIDER, IRoycoDayKernel.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        uint256 lptRawAfter = toUint256(accountant.getState().lastLPTRawNAV);
        assertGe(lptRawAfter, requiredFloor, "the max redemption must leave the required liquidity floor in the pool");
        assertLe(RoycoTestMath.computeLiquidityUtilization(_st, 0.05e18, lptRawAfter), WAD, "liquidity utilization must hold at or below 100% after the max redemption");
    }

    /**
     * @dev The shared redemption gate driver: finds the true gate boundary sStar (the largest share count the real
     *      kernel accepts) by binary search over previewRedeem, which routes through the production redemption path
     *      under the execute-and-revert simulation so a gate violation surfaces as the real gate error and no probe
     *      persists state. Asserts the advisory maxRedeem never advertises past sStar, that one share past sStar
     *      reverts on the gate from both the preview and the execution, and that redeeming exactly sStar succeeds
     * @dev Binary search rather than a closed-form invert because the redemption converts NAV to the coinvested
     *      collateral or BPT asset and back, and each hop floors, so the share-to-withdrawn-NAV map is not exact
     *      integer algebra the way the accountant's own effective-NAV boundary probes (kept in the accountant suite)
     *      are. The point re-homed here is only that the real kernel gate binds one share past its true boundary
     */
    function _assertRedeemGateEnforced(IRoycoVaultTranche _tranche, address _owner, bytes4 _gateError) internal returns (uint256 sStar) {
        uint256 reportedMax = _tranche.maxRedeem(_owner);
        assertGt(reportedMax, 0, "the advisory max redemption must be positive at the seed");

        // reportedMax is achievable, so it is a safe lower bound, and the owner's whole balance overshoots the gate,
        // so it is an unsafe upper bound: the true boundary sStar is the largest share count the preview accepts
        uint256 balance = _tranche.balanceOf(_owner);
        assertTrue(!_previewRedeemGateSafe(_tranche, balance, _gateError), "the full balance must overshoot the gate so one past the boundary is testable");
        sStar = _largestGateSafeRedeem(_tranche, _gateError, reportedMax, balance);
        assertLe(reportedMax, sStar, "the advisory max must not advertise past the true gate boundary");
        assertLt(sStar, balance, "the true gate boundary must sit below the full balance");

        // One share past the true boundary reverts on the gate from the preview and the execution alike (both leave
        // no state behind, the preview by simulation and the execution by revert)
        vm.expectRevert(_gateError);
        _tranche.previewRedeem(sStar + 1);
        vm.expectRevert(_gateError);
        vm.prank(_owner);
        _tranche.redeem(sStar + 1, _owner, _owner);

        // Redeeming exactly the boundary succeeds on the real kernel
        vm.prank(_owner);
        _tranche.redeem(sStar, _owner, _owner);
    }

    /// @dev The largest share count in [_lo, _hi] whose redemption preview clears the gate, by binary search
    function _largestGateSafeRedeem(IRoycoVaultTranche _tranche, bytes4 _gateError, uint256 _lo, uint256 _hi) internal returns (uint256) {
        while (_lo < _hi) {
            uint256 mid = _lo + (_hi - _lo + 1) / 2;
            if (_previewRedeemGateSafe(_tranche, mid, _gateError)) _lo = mid;
            else _hi = mid - 1;
        }
        return _lo;
    }

    /// @dev True when previewRedeem clears the gate, false when it reverts with the gate error (any other revert bubbles)
    function _previewRedeemGateSafe(IRoycoVaultTranche _tranche, uint256 _shares, bytes4 _gateError) internal returns (bool) {
        try _tranche.previewRedeem(_shares) returns (AssetClaims memory) {
            return true;
        } catch (bytes memory reason) {
            require(reason.length >= 4 && bytes4(reason) == _gateError, "previewRedeem reverted off the gate error under test");
            return false;
        }
    }
}
