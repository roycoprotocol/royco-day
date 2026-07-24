// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { AssetClaims, MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointMarketStateGating
 * @notice How queued requests interact with the market's state machine: in FIXED_TERM the MAX sentinel gracefully
 *         skips gated executions (maxDeposit/maxRedeem read 0) while explicit amounts revert in the kernel, the
 *         in-kind LPT deposit stays executable mid-term, requests survive the term and execute after recovery, and
 *         a liquidation-breached market pays the senior self-liquidation bonus through the entry point
 * @dev Seeded 100/30 to reuse the kernel suite's liquidation derivation: a -21% shared drawdown pushes
 *      coverageUtilizationWAD to ~7.6e18 >= the 6.4667e18 liquidation threshold (forced PERPETUAL)
 */
contract Test_EntryPointMarketStateGating is EntryPointTestBase {
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        _seedMarket(100 * stUnit, 30 * stUnit);
        _deployEntryPoint();
    }

    // ---------------------------------------------------------------------
    // FIXED_TERM
    // ---------------------------------------------------------------------

    function test_fixedTerm_maxSentinelGracefullySkips_explicitAmountReverts() public {
        // Queue a JT deposit and a JT redemption before the term
        uint256 amount = 5 * stUnit;
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), amount);
        (uint256 depositNonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);
        (uint256 redemptionNonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);

        _warpPastRedemptionDelay();
        _enterFixedTerm();

        // MAX-sentinel executions read the gated max as zero and skip without reverting, leaving the requests queued
        assertEq(_executeDepositMax(USER_A, USER_A, depositNonce), 0, "a gated deposit must gracefully skip under the MAX sentinel");
        assertAssetClaimsZero(_executeRedemptionMax(USER_A, USER_A, redemptionNonce), "a gated redemption must gracefully skip under the MAX sentinel");
        assertEq(entryPoint.getDepositRequest(USER_A, depositNonce).assets, toTrancheUnits(amount), "the skipped deposit request must remain queued");
        assertEq(entryPoint.getRedemptionRequest(USER_A, redemptionNonce).shares, shares, "the skipped redemption request must remain queued");

        // Explicit amounts reach the kernel's gate and revert
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, depositNonce, toTrancheUnits(amount));
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        vm.prank(USER_A);
        entryPoint.executeRedemption(USER_A, redemptionNonce, shares);
    }

    function test_fixedTerm_inKindLptDepositStaysExecutable() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(liquidityProviderTranche), 10e18, USER_A, 0);
        _warpPastDepositDelay();
        _enterFixedTerm();

        uint256 shares = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(shares, 0, "the in-kind LPT deposit must stay executable mid-term (liquidity-only deepening)");
    }

    function test_fixedTerm_requestsCanBeCreatedMidTerm() public {
        _enterFixedTerm();
        // The queue is always open: requests are registered mid-term and only execution is gated
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 5 * stUnit, USER_A, 0);
        assertGt(nonce, 0, "requests must be accepted while the market is in FIXED_TERM");
    }

    function test_fixedTerm_queuedRequestsExecuteAfterRecovery() public {
        uint256 amount = 5 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);
        _warpPastDepositDelay();
        _enterFixedTerm();
        assertEq(_executeDepositMax(USER_A, USER_A, nonce), 0, "the request must skip while the term is active");

        // The underlying recovers past the entry drawdown, clearing the IL and exiting the term
        applySTPnL(2600);
        SyncedAccountingState memory state = _sync();
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "the recovery must exit FIXED_TERM");

        uint256 shares = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(shares, 0, "the same queued request must execute after the term exits");
    }

    // ---------------------------------------------------------------------
    // Liquidation breach (forced PERPETUAL)
    // ---------------------------------------------------------------------

    /// @dev The forfeiture reference is the gate-free totalAssets view, which EXCLUDES the per-redemption
    ///      self-liquidation bonus (the kernel folds the bonus into stRedeem, not into the tranche total NAV), so the
    ///      bonus is never skimmed as queued yield and flows through to the redeemer on top of the request-time claim
    function test_liquidation_stRedemptionPaysSelfLiquidationBonusThroughEntryPoint() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_A, 0);
        _warpPastRedemptionDelay();
        _enterLiquidation();

        // The kernel folds the self-liquidation bonus into stRedeem, so the entry point's claims simply arrive larger:
        // compare the actual claims against the bonus-free pro-rata share of ST's effective NAV
        uint256 stEffectiveNAV = toUint256(seniorTranche.totalAssets().nav);
        uint256 proRataNAV = (stEffectiveNAV * shares) / seniorTranche.totalSupply();
        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);

        assertGt(toUint256(claims.nav), proRataNAV, "the liquidation-state redemption must carry the JT-funded self-liquidation bonus");
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonce).shares, 0, "the request must be fully executed");
    }

    /// @notice The self-liquidation bonus is EXCLUDED from the forfeiture skim: the reference is the bonus-free
    ///         totalAssets view, so a liquidation-state redemption forfeits nothing and the whole JT-funded bonus
    ///         reaches the redeemer on top of the pro-rata claim (hand-derived via the RoycoTestMath bonus mirror)
    function test_liquidation_selfLiqBonus_notSkimmedAsProtocolFees() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_A, 0);
        _warpPastRedemptionDelay();
        _enterLiquidation();

        // The bonus-free reference legs: the drawdown leaves vExec below vReq, so the skim must be zero
        SyncedAccountingState memory state = _sync();
        uint256 stSupply = seniorTranche.totalSupply();
        uint256 proRataNAV = (toUint256(seniorTranche.totalAssets().nav) * shares) / stSupply;
        // The expected bonus, independently derived from the synced state (the whole share count redeems: no skim)
        uint256 expectedBonusNAV = RoycoTestMath.seniorTrancheSelfLiquidationBonus(
            RoycoTestMath.SeniorTrancheSelfLiquidationBonusInputs({
                stEffectiveNAV: toUint256(state.stEffectiveNAV),
                jtEffectiveNAV: toUint256(state.jtEffectiveNAV),
                coverageUtilizationWAD: state.coverageUtilizationWAD,
                coverageLiquidationUtilizationWAD: state.coverageLiquidationUtilizationWAD,
                bonusWAD: defaultParams().stSelfLiquidationBonusWAD,
                userClaimNAV: RoycoTestMath.convertToValue(shares, toUint256(state.stEffectiveNAV), stSupply)
            })
        );
        assertGt(expectedBonusNAV, 0, "sanity: the breached market must grant a nonzero self-liquidation bonus");

        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);

        // The load-bearing exclusion: the bonus never registers as forfeitable queued yield
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(seniorTranche)), 0, "the self-liquidation bonus must never be skimmed as protocol fee shares");
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonce).shares, 0, "the request must be fully executed");
        // The delivered claim is the pro-rata leg plus the whole bonus (tolerance covers the asset-quantization round trip)
        assertGt(toUint256(claims.nav), proRataNAV, "the redemption must carry the JT-funded bonus on top of the pro-rata claim");
        assertApproxEqRel(toUint256(claims.nav), proRataNAV + expectedBonusNAV, 0.001e18, "the delivered claim must equal pro-rata plus the derived bonus");
    }

    /// @notice A gain in the queue followed by a still-breached market skims ONLY the standing-NAV gain: the fee
    ///         shares equal the exact value-formula skim (no bonus component), and the bonus rides on the post-skim
    ///         shares the user actually redeems
    function test_liquidation_gainThenBreach_skimIsStandingNavOnly_bonusRidesPostSkimShares() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(seniorTranche), 10 * stUnit);
        // Breach FIRST, then queue: the request snapshots the depressed value so a small recovery inside the
        // still-breached band produces a genuine standing-NAV gain over the queue
        _enterLiquidation();
        (uint256 nonce,) = _requestRedemption(USER_A, address(seniorTranche), shares, USER_A, 0);
        uint256 vReq = toUint256(entryPoint.getRedemptionRequest(USER_A, nonce).valueAtRequestTime);

        // A small recovery: the standing NAV rises but the market stays breached
        applySTPnL(100);
        SyncedAccountingState memory state = _sync();
        assertGe(state.coverageUtilizationWAD, state.coverageLiquidationUtilizationWAD, "setup: the market must remain liquidation-breached after the recovery");
        _warpPastRedemptionDelay();

        // The exact standing-NAV skim: derived purely from the bonus-free value formula (virtual-shares rate)
        uint256 vExec = RoycoTestMath.convertToValue(shares, toUint256(seniorTranche.totalAssets().nav), seniorTranche.totalSupply());
        assertGt(vExec, vReq, "sanity: the recovery must register as standing-NAV queued yield");
        uint256 expectedFee = Math.mulDiv(shares, vExec - vReq, vExec, Math.Rounding.Floor);

        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);

        // The skim is exactly the standing-NAV formula: no bonus component inflates it
        assertEq(
            entryPoint.getProtocolFeeSharesPendingCollection(address(seniorTranche)), expectedFee, "the skim must equal the exact bonus-free value-formula fee"
        );
        // The bonus rides on the post-skim shares: the delivered claim exceeds their bonus-free pro-rata value
        uint256 userSharesRedeemed = shares - expectedFee;
        uint256 postSkimProRata = Math.mulDiv(vExec, userSharesRedeemed, shares, Math.Rounding.Floor);
        assertGt(toUint256(claims.nav), postSkimProRata, "the post-skim redemption must still carry the self-liquidation bonus");
    }

    function test_liquidation_jtRedemptionGracefullySkips() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 5 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        _warpPastRedemptionDelay();
        // The 5 extra JT shares deepen the coverage buffer, so the breach needs a deeper drawdown than the 100/30 seed
        applySTPnL(-500);
        _enterLiquidation();

        // JT redemptions stay coverage-gated during liquidation: maxRedeem reads 0 and the MAX sentinel skips
        assertAssetClaimsZero(_executeRedemptionMax(USER_A, USER_A, nonce), "the coverage-gated JT redemption must gracefully skip");
        assertEq(entryPoint.getRedemptionRequest(USER_A, nonce).shares, shares, "the skipped request must remain queued");
    }
}
