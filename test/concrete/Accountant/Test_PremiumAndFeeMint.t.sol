// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ST_LP_ROLE } from "../../../src/factory/Roles.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_PremiumAndFeeMint
 * @notice Liquidity-premium- and fee-mint behaviors on the full mock market: a fee recipient without the LP role
 *         accrues fee shares but cannot redeem them until granted the role, and a griefed reinvestment stages the
 *         premium as idle senior shares
 * @dev The premium is minted as senior tranche shares to the kernel on every pre-op sync that books a senior gain
 *      (FeeAndLiquidityPremiumLogic._processFeesAndLiquidityPremium), so both behaviors ride the same mint
 */
contract Test_PremiumAndFeeMint is DayMarketTestBase {
    /// @dev Whole ST/JT vault shares seeded. Coverage after seed: (100 + 30) x 0.2 / 30 = 0.8667 <= 1, gate clears
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    uint256 internal collateralUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        collateralUnit = 10 ** uint256(cell.collateralAsset.decimals);
    }

    // =============================
    // Fee shares mint freely but redeem only for LP-role holders
    // =============================

    /**
     * @notice The protocol fee shares mint to a fee recipient that holds no tranche LP role — a fee accrual never
     *         bricks the sync — but the recipient cannot redeem those shares until it is separately granted the
     *         tranche LP role: redemption stays gated by ST_LP_ROLE
     * @dev This pins the accepted division of labor: minting is unconditional so every deposit and withdrawal that
     *      pre-op syncs stays alive for any fee recipient, while realizing the accrued fees is an explicit,
     *      per-recipient authorization step the operator performs when needed
     */
    function test_feeRecipientAccruesFees_butCannotRedeemUntilGrantedLpRole() public {
        // The fee recipient is deliberately NOT a senior LP (matching the production template, which does not grant
        // it the tranche LP roles): its redeem authorization is left to the operator
        (bool hasLpRole,) = accessManager.hasRole(ST_LP_ROLE, PROTOCOL_FEE_RECIPIENT);
        assertFalse(hasLpRole, "the fee recipient must start without the senior LP role");

        // Seed premium-free (flat rates), then book a +10% senior gain so the next sync carves a nonzero ST fee
        _seedMarket(ST_SEED_WHOLE * collateralUnit, JT_SEED_WHOLE * collateralUnit);
        applySTPnL(1000);
        _sync();

        // The fee mint landed on the recipient despite its missing LP role
        uint256 feeShares = seniorTranche.balanceOf(PROTOCOL_FEE_RECIPIENT);
        assertGt(feeShares, 0, "the ST protocol fee must mint senior shares to the fee recipient despite its missing LP role");

        // But it cannot realize them: `redeem` is restricted to ST_LP_ROLE, which the recipient does not hold
        vm.prank(PROTOCOL_FEE_RECIPIENT);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, PROTOCOL_FEE_RECIPIENT));
        seniorTranche.redeem(feeShares, PROTOCOL_FEE_RECIPIENT, PROTOCOL_FEE_RECIPIENT);

        // Once the operator grants the LP role (the accepted resolution), the same shares redeem
        accessManager.grantRole(ST_LP_ROLE, PROTOCOL_FEE_RECIPIENT, 0);
        uint256 redeemable = seniorTranche.maxRedeem(PROTOCOL_FEE_RECIPIENT);
        assertGt(redeemable, 0, "an LP-role-holding fee recipient can now redeem its accrued fee shares");
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
     *         freshly minted senior shares stay idle in the kernel (lptOwnedSeniorTrancheShares), not deployed into
     *         lptRawNAV and not forfeited. The un-deployed premium is held by the kernel as idle liquidity premium
     *         senior shares, claimable and never forfeited, and a tranche operation tolerates a failing
     *         reinvestment without reverting
     * @dev An attacker forcing venue slippage only defers deployment: the metric keeps reading under-provisioned
     *      (lptRawNAV excludes the idle shares) so the LDM keeps paying
     */
    function test_griefedReinvestment_stagesPremiumAsIdleSeniorShares() public {
        _seedMarket(ST_SEED_WHOLE * collateralUnit, JT_SEED_WHOLE * collateralUnit);

        // Arm persistent venue slippage so the single-sided reinvestment deterministically fails its min-BPT-out
        setVenueSlippageMode(true);

        // Record the pre-gain staged premium (zero, seeding was flat) and pool depth
        uint256 stagedBefore = kernel.getState().lptOwnedSeniorTrancheShares;
        assertEq(stagedBefore, 0, "no premium is staged after a flat seed");
        uint256 lptRawBefore = toUint256(accountant.getState().lastLPTRawNAV);

        // Book a +10% senior gain, then sync: the premium mints but the reinvestment is rejected by the gate
        applySTPnL(1000);
        SyncedAccountingState memory s = _sync();

        // The sync does not revert, the premium is staged (not deployed, not forfeited)
        uint256 stagedAfter = kernel.getState().lptOwnedSeniorTrancheShares;
        assertGt(stagedAfter, stagedBefore, "the griefed premium is staged as idle senior shares, not forfeited");
        // lptRawNAV (the BPT depth) does not grow from the premium: the staged pile stays out of the liquidity metric
        assertEq(toUint256(s.lptRawNAV), lptRawBefore, "the failed reinvestment leaves pool depth unchanged, so the metric stays under-provisioned");
    }
}
