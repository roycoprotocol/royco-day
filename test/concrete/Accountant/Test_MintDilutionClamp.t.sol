// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { JT_LP_ROLE } from "../../../src/factory/RolesConfiguration.sol";
import { MINT_DILUTION_RESIDUAL_WAD, WAD } from "../../../src/libraries/Constants.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title Test_MintDilutionClamp_JuniorTranche
 * @notice End-to-end pins of the mint-dilution clamp (MINT_DILUTION_RESIDUAL_WAD = 1e6, a 1e-12 residual)
 *         through the real tranche deposit and preview paths:
 *         (i)  a live-market deposit mints fair-priced shares — the clamp is provably inert outside
 *              degenerate states, so healthy-market pricing is bit-identical to the pre-clamp formula;
 *         (ii) a deposit into a wiped-to-zero junior tranche (the junior-wipeout dilution state) mints exactly the cap
 *              floor(supply x (WAD - eps) / eps) — near-total capture with bounded supply growth — with
 *              preview parity holding on the clamped branch
 * @dev The wipe uses a -40% shared-rate move: jtRawNAV 30_000e18 -> 18_000e18 absorbs its own 12_000e18 loss, and
 *      coverage for the senior's 40_000e18 loss consumes exactly the remaining 18_000e18, so jtEffectiveNAV
 *      lands at exactly zero with the junior supply still outstanding; the (jtEffectiveNAV == 0 && stEffectiveNAV > 0) arm then
 *      forces PERPETUAL, so deposits stay enabled in the wiped state
 */
contract Test_MintDilutionClamp_JuniorTranche is DayMarketTestBase {
    address internal jtActor;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        _seedMarket(100_000e18, 30_000e18);
        jtActor = _generateActor("CLAMP_JT_ACTOR", JT_LP_ROLE);
    }

    /// @dev Deposits vault shares into the junior tranche as the clamp actor through the production path
    function _depositJT(uint256 _assets) internal returns (uint256 minted) {
        stJtVault.mintShares(jtActor, _assets);
        vm.startPrank(jtActor);
        stJtVault.approve(address(juniorTranche), _assets);
        minted = juniorTranche.deposit(toTrancheUnits(_assets), jtActor);
        vm.stopPrank();
    }

    /**
     * @notice (i) In a live market the clamp is inert: the deposit mints exactly the fair floor formula and
     *         the preview matches the execution. The bind would require the whole junior tranche to be worth
     *         under ~1e-12 of the deposit, which no healthy state approaches
     */
    function test_MintDilutionClamp_LiveMarketDeposit_InertAndFairPriced() public {
        SyncedAccountingState memory state = _sync();
        uint256 supplyBefore = juniorTranche.totalSupply();
        uint256 jtEffBefore = toUint256(state.jtEffectiveNAV);
        uint256 assets = 1000e18;
        uint256 value = toUint256(kernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets)));

        uint256 predicted = juniorTranche.previewDeposit(toTrancheUnits(assets));
        uint256 minted = _depositJT(assets);

        assertEq(minted, Math.mulDiv(supplyBefore, value, jtEffBefore), "live-market mint is the fair floor formula");
        assertEq(minted, predicted, "preview parity at the fair-priced mint");
        assertEq(minted, RoycoTestMath.convertToShares(value, jtEffBefore, supplyBefore), "mirror agreement at the fair-priced mint");
    }

    /**
     * @notice (ii) The I17 dilution state: the junior tranche is wiped to exactly zero effective NAV with its
     *         supply outstanding, then a depositor enters. The mint is exactly the cap
     *         floor(supply x (WAD - eps) / eps) = supply x (1e12 - 1): the depositor captures all but one
     *         part in 1e12 of the tranche, and the supply grows by a bounded factor instead of x value
     *         (pre-clamp, this deposit would have minted supply x value ~ 1e21 times more). Preview parity
     *         must hold on the clamped branch too
     */
    function test_MintDilutionClamp_WipedTrancheDeposit_MintsExactlyTheCapWithPreviewParity() public {
        // Wipe the junior tranche to exactly zero effective NAV (see the contract docstring derivation)
        applySTPnL(-4000);
        SyncedAccountingState memory state = _sync();
        assertEq(toUint256(state.jtEffectiveNAV), 0, "the wipe must land the junior effective NAV at exactly zero");
        uint256 supplyBefore = juniorTranche.totalSupply();
        assertGt(supplyBefore, 0, "the wiped supply must remain outstanding");

        uint256 assets = 1e18;
        uint256 value = toUint256(kernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets)));
        // The bind holds: value ~ 0.6e18 NAV wei over the 1-wei pinned denominator, far past the ~1e12 bind threshold
        assertGt(value * MINT_DILUTION_RESIDUAL_WAD, WAD - MINT_DILUTION_RESIDUAL_WAD, "the dilution deposit must bind the clamp");
        uint256 cap = Math.mulDiv(supplyBefore, WAD - MINT_DILUTION_RESIDUAL_WAD, MINT_DILUTION_RESIDUAL_WAD);

        uint256 predicted = juniorTranche.previewDeposit(toTrancheUnits(assets));
        uint256 minted = _depositJT(assets);

        assertEq(minted, cap, "the dilution mint clamps to exactly the cap");
        assertEq(minted, predicted, "preview parity at the clamped mint");
        assertEq(minted, RoycoTestMath.convertToShares(value, 0, supplyBefore), "mirror agreement at the clamped mint");

        // The capture guarantee in both directions: the depositor owns at most (1 - residual) of the post-mint
        // supply, and at least that minus the cap's floor dust — near-total capture, bounded growth
        assertLe(minted * MINT_DILUTION_RESIDUAL_WAD, supplyBefore * (WAD - MINT_DILUTION_RESIDUAL_WAD), "the mint never exceeds the ownership bound");
    }
}
