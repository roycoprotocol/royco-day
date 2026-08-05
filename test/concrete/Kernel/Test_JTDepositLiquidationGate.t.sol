// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MarketFuzzTestBase } from "../../utils/MarketFuzzTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title Test_JTDepositLiquidationGate_Kernel
 * @notice Pins the post-op JT deposit gate: while the self-liquidation bonus regime is active (coverage utilization
 *         at or above the liquidation threshold), the only JT deposit allowed is one that settles the market
 *         strictly below the threshold. A sub-curing deposit would refill the bonus pool that ST redemptions drain
 *         from junior NAV, so it reverts on JT_DEPOSIT_BLOCKED_DURING_LIQUIDATION through both the execution path
 *         and the execute-and-revert preview seam
 * @dev Every market seeds flat (1000e18 ST, 400e18 JT, a deep quote-only pool so liquidity never binds) at the
 *      default parameterization: minCoverage 0.2e18 and liquidation threshold L = 6.4667e18. The crash is a shared
 *      collateral-price drop (applySTPnL scales the oracle), so the junior buffer absorbs the whole loss and the
 *      post-crash marks stay exact integer algebra: at price r the collateral mark is floor(1400e18 * r / WAD) and jtEffectiveNAV is that mark minus the
 *      protected 1000e18 senior NAV (or zero once the buffer is wiped). The gate binds on the post-op mark
 *      C2 = quote(1400e18 + a), so the cure condition ceil(C2 * m / (C2 - stEff)) < L inverts to an exact smallest
 *      curing deposit, and each test pins that inversion against the kernel's live conversion before relying on it
 */
contract Test_JTDepositLiquidationGate_Kernel is MarketFuzzTestBase {
    /// @dev The flat seed sizes shared by every test: 1000e18 ST over 400e18 JT puts the healthy market at 0.7e18 utilization
    uint256 internal constant ST_SEED = 1000e18;
    uint256 internal constant JT_SEED = 400e18;
    uint256 internal constant TOTAL_SEED = ST_SEED + JT_SEED;

    /// @dev Seeds the shared flat market with a deep quote-only pool so the coverage leg is the only live gate
    function _seedDeep() internal {
        _seedFlatMarket(ST_SEED, JT_SEED, 2e8);
    }

    /// @dev The kernel's live collateral quote for a vault-share amount at the current (possibly crashed) collateral price
    function _quote(uint256 _assets) internal view returns (uint256) {
        return toUint256(kernel.convertCollateralAssetsToValue(toTrancheUnits(_assets)));
    }

    /// @dev Mints and attempts a JT deposit expecting the given revert, mirroring _expectSeniorDepositReverts
    function _expectJuniorDepositReverts(uint256 _assets, bytes4 _error) internal {
        stJtVault.mintShares(JT_PROVIDER, _assets);
        vm.startPrank(JT_PROVIDER);
        stJtVault.approve(address(juniorTranche), _assets);
        vm.expectRevert(_error);
        juniorTranche.deposit(toTrancheUnits(_assets), JT_PROVIDER);
        vm.stopPrank();
    }

    /// @dev The settled coverage utilization recomputed from the accountant's checkpointed marks
    function _settledUtilization() internal view returns (uint256) {
        IRoycoDayAccountant.RoycoDayAccountantState memory acct = accountant.getState();
        return RoycoTestMath.computeCoverageUtilization(toUint256(acct.lastCollateralNAV), params.minCoverageWAD, toUint256(acct.lastJTEffectiveNAV));
    }

    /**
     * Scenario: the rate crash lands the market deep inside the bonus regime (price 0.72 puts the mark at 1008e18
     * over an 8e18 junior buffer, utilization 25.2e18 against the 6.4667e18 threshold), and a 1e18 deposit leaves
     * it there. The sub-curing deposit must revert on the gate through the preview seam and the execution path
     */
    function test_JTDeposit_RevertIf_SubCuringDepositDuringActiveLiquidation() public {
        _seedDeep();
        applySTPnL(-2800); // collateral price 0.72e18

        // The crashed mark and the armed regime, pinned against the live conversion
        uint256 c1 = _quote(TOTAL_SEED);
        assertEq(c1, 1008e18, "the 0.72 price must mark the collateral at exactly 1008e18");
        assertGe(
            RoycoTestMath.computeCoverageUtilization(c1, params.minCoverageWAD, c1 - ST_SEED),
            params.coverageLiquidationUtilizationWAD,
            "the crash must arm the liquidation regime"
        );

        // The preview seam runs the real flow, so it rejects the sub-curing deposit with the same gate error
        vm.expectRevert(IRoycoDayKernel.JT_DEPOSIT_BLOCKED_DURING_LIQUIDATION.selector);
        juniorTranche.previewDeposit(toTrancheUnits(uint256(1e18)));

        // The execution path rejects it identically
        _expectJuniorDepositReverts(1e18, IRoycoDayKernel.JT_DEPOSIT_BLOCKED_DURING_LIQUIDATION.selector);
    }

    /**
     * Scenario: the exact cure boundary, one asset wei apart. The cure condition on the post-op mark
     * C2 = quote(1400e18 + a) with the protected 1000e18 senior NAV is
     *   ceil(C2 * m / (C2 - 1000e18)) < L  <=>  C2 * m <= (C2 - 1000e18) * (L - 1)
     *                                      <=>  C2 >= ceil(1000e18 * (L - 1) / (L - 1 - m)) =: c2Star
     * and quote floors a * 0.72, so the smallest curing deposit is aHigh = ceil(c2Star * WAD / 0.72e18) - 1400e18.
     * One asset wei below aHigh reverts on the gate, aHigh itself passes the preview and settles the market
     * strictly below the threshold, disarming the bonus
     */
    function test_JTDeposit_ExactCureBoundary_OneAssetWeiApart() public {
        _seedDeep();
        applySTPnL(-2800); // collateral price 0.72e18
        uint256 liquidationThreshold = params.coverageLiquidationUtilizationWAD;

        // The smallest curing post-op mark and its deposit-size inversion (derivation above)
        uint256 c2Star = Math.ceilDiv(ST_SEED * (liquidationThreshold - 1), liquidationThreshold - 1 - params.minCoverageWAD);
        uint256 aHigh = Math.ceilDiv(c2Star * WAD, 0.72e18) - TOTAL_SEED;

        // Pin the inversion against the kernel's live conversion before relying on it
        assertGe(_quote(TOTAL_SEED + aHigh), c2Star, "aHigh must reach the curing mark");
        assertLt(_quote(TOTAL_SEED + aHigh - 1), c2Star, "one asset wei less must fall short of the curing mark");

        // One asset wei below the cure reverts on the gate through the preview seam and the execution path
        vm.expectRevert(IRoycoDayKernel.JT_DEPOSIT_BLOCKED_DURING_LIQUIDATION.selector);
        juniorTranche.previewDeposit(toTrancheUnits(aHigh - 1));
        _expectJuniorDepositReverts(aHigh - 1, IRoycoDayKernel.JT_DEPOSIT_BLOCKED_DURING_LIQUIDATION.selector);

        // The smallest curing deposit passes the preview and settles, and both agree on the minted shares
        uint256 previewedShares = juniorTranche.previewDeposit(toTrancheUnits(aHigh));
        uint256 mintedShares = _depositJunior(aHigh);
        assertEq(mintedShares, previewedShares, "the curing deposit's preview must match its execution");
        assertGt(mintedShares, 0, "the curing deposit must mint shares");

        // The settled market sits strictly below the threshold: the bonus regime is disarmed
        assertLt(_settledUtilization(), liquidationThreshold, "the curing deposit must disarm the liquidation regime");
    }

    /**
     * Scenario: the stressed band between WAD and the liquidation threshold (price 0.79 marks the collateral at
     * 1106e18 over a 106e18 buffer, utilization ~2.09e18), where the two JT-deposit gates layer. In a fixed-term
     * capable market the covered drawdown opens a JT observation period, so the band rejects on the fixed-term
     * gate before the liquidation gate can matter. In a permanently perpetual market (fixed-term duration zero)
     * the band has no observation period and JT deposits stay open: the liquidation gate binds at the threshold,
     * not at the WAD coverage boundary that gates ST deposits and JT redemptions
     */
    function test_JTDeposit_StressedBand_FixedTermGatesTheTermCapableMarketAndPerpetualStaysOpen() public {
        _seedDeep();

        // A fixed-term capable market closes the band through the JT observation period, not the liquidation gate
        applySTPnL(-2100); // collateral price 0.79e18
        uint256 c1 = _quote(TOTAL_SEED);
        uint256 utilization = RoycoTestMath.computeCoverageUtilization(c1, params.minCoverageWAD, c1 - ST_SEED);
        assertGt(utilization, WAD, "the crash must breach the WAD coverage boundary");
        assertLt(utilization, params.coverageLiquidationUtilizationWAD, "the crash must stay below the liquidation threshold");
        _expectJuniorDepositReverts(1e18, IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);

        // A permanently perpetual market never enters the observation period, so the band is live for JT deposits
        vm.prank(ACCOUNTANT_ADMIN);
        accountant.setFixedTermDuration(0);
        uint256 mintedShares = _depositJunior(1e18);
        assertGt(mintedShares, 0, "the stressed-band deposit must mint shares in the perpetual market");
        uint256 settled = _settledUtilization();
        assertGt(settled, WAD, "the small deposit must leave the market above the WAD boundary");
        assertLt(settled, params.coverageLiquidationUtilizationWAD, "the settled market must stay below the liquidation threshold");
    }

    /**
     * Scenario: the wiped-buffer edge (price 0.7 marks the collateral at 980e18, below the 1000e18 senior NAV, so
     * the junior buffer is zero and utilization reads infinite through the zero-buffer branch). A sub-curing
     * deposit reverts, and the cure inversion with the residual 980e18 senior NAV
     *   C2 >= ceil(980e18 * (L - 1) / (L - 1 - m))
     * still admits a deposit large enough to rebuild the buffer past the threshold in one shot
     */
    function test_JTDeposit_WipedBuffer_SubCureRevertsAndFullCureSettles() public {
        _seedDeep();
        applySTPnL(-3000); // collateral price 0.7e18
        uint256 liquidationThreshold = params.coverageLiquidationUtilizationWAD;

        // The wiped buffer: the mark falls below the protected senior NAV, so the senior takes the residual loss
        uint256 c1 = _quote(TOTAL_SEED);
        assertEq(c1, 980e18, "the 0.7 price must mark the collateral at exactly 980e18");
        assertLt(c1, ST_SEED, "the buffer must be wiped");

        // A sub-curing deposit into the infinite-utilization state reverts on the gate
        _expectJuniorDepositReverts(1e18, IRoycoDayKernel.JT_DEPOSIT_BLOCKED_DURING_LIQUIDATION.selector);

        // The cure inversion against the residual senior NAV (the senior absorbed the loss past the buffer)
        uint256 c2Star = Math.ceilDiv(c1 * (liquidationThreshold - 1), liquidationThreshold - 1 - params.minCoverageWAD);
        uint256 aHigh = Math.ceilDiv(c2Star * WAD, 0.7e18) - TOTAL_SEED;
        assertGe(_quote(TOTAL_SEED + aHigh), c2Star, "aHigh must reach the curing mark");
        assertLt(_quote(TOTAL_SEED + aHigh - 1), c2Star, "one asset wei less must fall short of the curing mark");

        // One wei short still reverts, the full cure settles below the threshold
        _expectJuniorDepositReverts(aHigh - 1, IRoycoDayKernel.JT_DEPOSIT_BLOCKED_DURING_LIQUIDATION.selector);
        uint256 mintedShares = _depositJunior(aHigh);
        assertGt(mintedShares, 0, "the curing deposit must mint shares through the collapsed-price mint path");
        assertLt(_settledUtilization(), liquidationThreshold, "the curing deposit must disarm the liquidation regime");
    }
}
