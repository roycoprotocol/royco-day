// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_WhitelistPremiumMint
 * @notice Two liquidity-premium-mint behaviors on the full mock market: a whitelist-transfer market syncs
 *         cleanly after a senior gain because the kernel and fee recipient hold the tranche LP roles, and a
 *         griefed reinvestment stages the premium as idle senior shares
 * @dev The premium is minted as senior tranche shares to the kernel on every pre-op sync that books a senior gain
 *      (FeeAndLiquidityPremiumLogic._processFeesAndLiquidityPremium), so both behaviors ride the same mint
 */
contract Test_WhitelistPremiumMint is DayMarketTestBase {
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
    // A whitelist-transfer market syncs cleanly on the first senior gain
    // =============================

    /**
     * @notice In a market that enforces the tranche-transfer whitelist, the liquidity-premium mint to the kernel
     *         and the protocol-fee mints to the fee recipient pass the tranche `_update` whitelist screen, so a
     *         senior gain syncs cleanly and the market keeps functioning
     * @dev The deployment grants the kernel and the protocol fee recipient the tranche LP roles, so the premium
     *      is minted as senior shares to the kernel and the mint's _update hook accepts the kernel and the fee
     *      recipient as whitelisted recipients (RoycoDayKernel.preTrancheBalanceUpdateHook, the
     *      ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER branch)
     */
    function test_whitelistMarket_premiumMintPassesWhitelist_syncsCleanlyAfterGain() public {
        // Redeploy the market with the tranche-transfer whitelist enforced
        MarketParamsConfig memory p = defaultParams();
        p.enforceWhitelistOnTransfer = true;
        _deployMarket(cellA(), p);
        stUnit = 10 ** uint256(cell.stAsset.decimals);

        // Seeding is premium-free (rates are flat), so the whitelist market seeds cleanly
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);

        // Book a +10% senior gain so the next sync accrues a nonzero liquidity premium (and protocol fees) to mint
        applySTPnL(1000);

        // The premium mint to the kernel and the fee mints to the fee recipient pass the whitelist screen.
        _sync(); // no revert

        // The market keeps functioning: a subsequent whitelisted senior deposit (which pre-op syncs, minting the
        // premium/fees again) also lands.
        uint256 more = 10 * stUnit;
        stJtVault.mintShares(ST_PROVIDER, more);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), more);
        seniorTranche.deposit(toTrancheUnits(more), ST_PROVIDER);
        vm.stopPrank();
    }

    // =============================
    // A griefed reinvestment stages the premium as idle senior shares
    // =============================

    /**
     * @notice When the single-sided reinvestment fails the slippage gate, the premium mint still succeeds and the
     *         freshly minted senior shares stay idle in the kernel (ltOwnedSeniorTrancheShares), not deployed into
     *         ltRawNAV and not forfeited. The un-deployed premium is held by the kernel as idle liquidity premium
     *         senior shares, claimable and never forfeited, and a tranche operation tolerates a failing
     *         reinvestment without reverting
     * @dev An attacker forcing venue slippage only defers deployment: the metric keeps reading under-provisioned
     *      (ltRawNAV excludes the idle shares) so the LDM keeps paying
     */
    function test_griefedReinvestment_stagesPremiumAsIdleSeniorShares() public {
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

        // The sync does not revert, the premium is staged (not deployed, not forfeited)
        uint256 stagedAfter = kernel.getState().ltOwnedSeniorTrancheShares;
        assertGt(stagedAfter, stagedBefore, "the griefed premium is staged as idle senior shares, not forfeited");
        // ltRawNAV (the BPT depth) does not grow from the premium: the staged pile stays out of the liquidity metric
        assertEq(toUint256(s.ltRawNAV), ltRawBefore, "the failed reinvestment leaves pool depth unchanged, so the metric stays under-provisioned");
    }
}
