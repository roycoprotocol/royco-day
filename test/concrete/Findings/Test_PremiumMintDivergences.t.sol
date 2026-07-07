// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_PremiumMintDivergences_DayMarket
 * @notice Loud, first-class pins of the two liquidity-premium-mint behaviors that reproduce on the full mock
 *         market: the whitelist-transfer brick (a confirmed defect) and the griefed reinvestment leaving idle
 *         liquidity premium senior shares (documented, intended behavior). Findings 11-12 of the ledger
 *         docs/testing/agent-notes/13-spec-divergence-findings.md
 * @dev The premium is minted as senior tranche shares to the kernel on every pre-op sync that books a senior gain
 *      (FeeAndLiquidityPremiumLogic._processFeesAndLiquidityPremium), so both behaviors ride the same mint the
 *      spec makes load-bearing
 */
contract Test_PremiumMintDivergences_DayMarket is DayMarketTestBase {
    /// @dev Whole ST/JT vault shares seeded. Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1, gate clears
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    uint256 internal stUnit;

    function setUp() public {
        // The default (non-whitelist) market backs the griefed-reinvestment pin; the whitelist pin redeploys
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
    }

    // =============================
    // FINDING 11 — a whitelist-transfer market bricks on the first senior gain
    // =============================

    /**
     * @notice FINDING 11: in a market that enforces the tranche-transfer whitelist, the liquidity-premium mint
     *         reverts ACCOUNT_NOT_WHITELISTED_TRANCHE_LP(kernel), because the premium is minted as senior shares to
     *         the kernel and the mint's _update hook screens the kernel as an un-whitelisted recipient
     *         (RoycoDayKernel.preTrancheBalanceUpdateHook, the ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER branch)
     * @dev CONSEQUENCE: once any senior gain accrues a premium, EVERY sync (hence every deposit and redemption,
     *      which all pre-op sync) reverts. The whole market is bricked. SPEC-EXPECTED: the privileged internal
     *      premium mint bypasses the transfer whitelist, so a whitelist market keeps functioning
     * @dev The kernel is never granted the senior tranche's deposit (LP) role, so canCall(kernel, ST, deposit) is
     *      false and the hook's `_to != authority && isWhitelistedTrancheLP` requirement fails on the kernel
     */
    function test_FINDING_11_whitelistMarket_bricksOnFirstSeniorGainPremiumMint() public {
        // Redeploy the market with the tranche-transfer whitelist enforced
        MarketParamsConfig memory p = defaultParams();
        p.enforceWhitelistOnTransfer = true;
        _deployMarket(cellA(), p);
        stUnit = 10 ** uint256(cell.stAsset.decimals);

        // Seeding is premium-free (rates are flat), so the whitelist market seeds cleanly
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);

        // Book a +10% senior gain so the next sync accrues a nonzero liquidity premium to mint
        applySTPnL(1000);

        // ACTUAL: the premium mint transfers senior shares to the kernel, which the whitelist hook rejects
        // SPEC-EXPECTED: the privileged premium mint bypasses the whitelist, so the sync succeeds
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayKernel.ACCOUNT_NOT_WHITELISTED_TRANCHE_LP.selector, address(kernel)));
        _sync();
    }

    // =============================
    // FINDING 12 — a griefed reinvestment leaves the premium staged and claimable, not forfeited
    // =============================

    /**
     * @notice FINDING 12 (intended behavior): when the single-sided reinvestment fails the slippage gate, the
     *         premium mint still succeeds and the freshly minted senior shares stay idle in the kernel
     *         (ltOwnedSeniorTrancheShares), NOT deployed into ltRawNAV and NOT forfeited. This matches CLAUDE.md:
     *         the un-deployed premium is held by the kernel as idle liquidity premium senior shares, claimable
     *         and never forfeited, and a tranche operation tolerates a failing reinvestment without reverting
     * @dev This pins the CURRENT (correct) behavior so a future change that either reverts the sync on a failed
     *      reinvestment, or silently drops the idle premium shares, fails loudly. An attacker forcing venue
     *      slippage only DEFERS deployment; the metric keeps reading under-provisioned (ltRawNAV excludes the
     *      idle shares) so the LDM keeps paying
     */
    function test_FINDING_12_griefedReinvestment_stagesPremiumClaimableNotForfeited() public {
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);

        // Arm persistent venue slippage so the single-sided reinvestment deterministically fails its min-BPT-out
        setVenueSlippageMode(true);

        // Record the pre-gain staged premium (zero, seeding was flat) and pool depth
        uint256 stagedBefore = kernel.getState().ltOwnedSeniorTrancheShares;
        assertEq(stagedBefore, 0, "no premium is staged after a flat seed");
        uint256 ltRawBefore = toUint256(accountant.getState().lastLTRawNAV);

        // Book a +10% senior gain, then sync: the premium mints but the reinvestment is rejected by the gate
        applySTPnL(1000);
        SyncedAccountingState memory s = _sync();

        // ACTUAL and SPEC-EXPECTED: the sync does not revert, the premium is staged (not deployed, not forfeited)
        uint256 stagedAfter = kernel.getState().ltOwnedSeniorTrancheShares;
        assertGt(stagedAfter, stagedBefore, "the griefed premium is staged as idle senior shares, not forfeited");
        // ltRawNAV (the BPT depth) does not grow from the premium: the staged pile stays out of the liquidity metric
        assertEq(toUint256(s.ltRawNAV), ltRawBefore, "the failed reinvestment leaves pool depth unchanged, so the metric stays under-provisioned");
    }
}
