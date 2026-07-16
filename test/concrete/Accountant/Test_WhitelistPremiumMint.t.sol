// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ST_LP_ROLE } from "../../../src/factory/RolesConfiguration.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_WhitelistPremiumMint
 * @notice Liquidity-premium- and fee-mint behaviors on the full mock market: a whitelist-transfer market syncs
 *         cleanly after a senior gain because the kernel hook exempts the kernel and the fee recipient from the LP
 *         receive-screen by address, a fee recipient without the LP role can receive but not redeem its fees, and a
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
     * @dev The kernel hook exempts the kernel and the fee recipient by address, not by LP role: the premium is
     *      minted as senior shares to the kernel (_to == address(this)) and the fee shares to the fee recipient
     *      (_to == protocolFeeRecipient), and both are exempt from the receive-screen
     *      (RoycoDayKernel.preTrancheBalanceUpdateHook, the ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER branch)
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

    /**
     * @notice On a whitelist-enforcing market, the protocol fee shares mint to a fee recipient that is NOT a
     *         whitelisted tranche LP (the hook's `_to == protocolFeeRecipient` exemption lets the mint through, so
     *         a fee accrual never bricks the sync), but the fee recipient cannot redeem those shares until it is
     *         separately granted the tranche LP role — redemption stays gated by ST_LP_ROLE
     * @dev This pins the accepted division of labor: the by-address exemption keeps the mint (and therefore every
     *      deposit and withdrawal that pre-op syncs) alive for any fee recipient, while realizing the accrued fees
     *      is an explicit, per-recipient whitelisting step the operator performs when needed. It is the mirror of
     *      the kernel, which only ever receives its custody shares and so needs no redeem authorization at all
     */
    function test_whitelistMarket_feeRecipientReceivesFeesWithoutLpRole_butCannotRedeemUntilWhitelisted() public {
        // Redeploy the market with the tranche-transfer whitelist enforced
        MarketParamsConfig memory p = defaultParams();
        p.enforceWhitelistOnTransfer = true;
        _deployMarket(cellA(), p);
        stUnit = 10 ** uint256(cell.stAsset.decimals);

        // The fee recipient is deliberately NOT a whitelisted senior LP (matching the production template, which
        // no longer grants it the tranche LP roles): its redeem authorization is left to the operator
        (bool hasLpRole,) = accessManager.hasRole(ST_LP_ROLE, PROTOCOL_FEE_RECIPIENT);
        assertFalse(hasLpRole, "the fee recipient must start without the senior LP role");

        // Seed premium-free (flat rates), then book a +10% senior gain so the next sync carves a nonzero ST fee
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
        applySTPnL(1000);
        _sync();

        // The fee mint landed on the non-whitelisted recipient purely through the by-address hook exemption
        uint256 feeShares = seniorTranche.balanceOf(PROTOCOL_FEE_RECIPIENT);
        assertGt(feeShares, 0, "the ST protocol fee must mint senior shares to the fee recipient despite its missing LP role");

        // But it cannot realize them: `redeem` is restricted to ST_LP_ROLE, which the recipient does not hold
        vm.prank(PROTOCOL_FEE_RECIPIENT);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, PROTOCOL_FEE_RECIPIENT));
        seniorTranche.redeem(feeShares, PROTOCOL_FEE_RECIPIENT, PROTOCOL_FEE_RECIPIENT);

        // Once the operator whitelists the recipient (the accepted resolution), the same shares redeem
        accessManager.grantRole(ST_LP_ROLE, PROTOCOL_FEE_RECIPIENT, 0);
        uint256 redeemable = seniorTranche.maxRedeem(PROTOCOL_FEE_RECIPIENT);
        assertGt(redeemable, 0, "a whitelisted fee recipient can now redeem its accrued fee shares");
        uint256 vaultSharesBefore = stJtVault.balanceOf(PROTOCOL_FEE_RECIPIENT);
        vm.prank(PROTOCOL_FEE_RECIPIENT);
        seniorTranche.redeem(redeemable, PROTOCOL_FEE_RECIPIENT, PROTOCOL_FEE_RECIPIENT);
        assertEq(seniorTranche.balanceOf(PROTOCOL_FEE_RECIPIENT), feeShares - redeemable, "the redeemed fee shares are burned from the recipient");
        assertGt(
            stJtVault.balanceOf(PROTOCOL_FEE_RECIPIENT) - vaultSharesBefore, 0, "redeeming the fee shares returns underlying vault shares to the recipient"
        );
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
