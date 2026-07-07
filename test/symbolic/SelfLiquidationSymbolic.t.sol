// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { AssetClaims, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toTrancheUnits } from "../../src/libraries/Units.sol";
import { UtilizationLogic } from "../../src/libraries/logic/UtilizationLogic.sol";
import { SelfLiquidationHarness } from "../mocks/SelfLiquidationHarness.sol";

/**
 * @title SelfLiquidationSymbolicSpec
 * @notice Halmos symbolic specs for the senior tranche self-liquidation bonus. The load-bearing chain: on every
 *         reachable liquidation-breach state the covered exposure strictly exceeds the junior buffer, which makes
 *         both coverage-utilization-neutral bonus denominators positive, which makes the bonus computation total
 *         (never reverts), so a redeeming senior LP can always exit a market that is in liquidation
 * @dev Run with `halmos --contract SelfLiquidationSymbolicSpec`. Functions prefixed check_ are halmos properties
 *      and are not discovered by forge test. Domain: NAVs and user claims up to 1e30 NAV wei, minCoverage below
 *      WAD and liquidation threshold above WAD (the accountant's validated config range), bonus rate up to WAD.
 *      The breach implication is derived independently from ceil(a/b) > WAD iff a > WAD*b, never by re-running
 *      the production denominator subtraction as its own expectation
 */
contract SelfLiquidationSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei (one trillion tokens at WAD precision)
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    SelfLiquidationHarness internal sll;

    function setUp() public {
        sll = new SelfLiquidationHarness();
    }

    /*//////////////////////////////////////////////////////////////////////
                            EXTERNAL WRAPPER
    //////////////////////////////////////////////////////////////////////*/

    /// @dev External wrapper so the totality check can observe a revert (from any frame of the bonus computation) through try/catch
    function applyBonusWrapped(
        SyncedAccountingState memory _state,
        AssetClaims memory _stUserClaims
    )
        external
        view
        returns (AssetClaims memory, NAV_UNIT)
    {
        return sll.applyBonus(_state, _stUserClaims);
    }

    /*//////////////////////////////////////////////////////////////////////
                    BREACH IMPLIES A POSITIVE BONUS DENOMINATOR
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On every liquidation-breach state with a live junior buffer, the covered exposure strictly exceeds
     *         the junior effective NAV. This is exactly the positivity of both unchecked denominators in the
     *         coverage-utilization-neutral bonus math (exposure - jtEff, and exposure - (coinvested ? jtEff : 0)),
     *         so the bonus can never divide by zero or underflow on a reachable breach: a redeeming senior LP is
     *         never bricked out of exiting a market that is in liquidation
     * @dev Independent derivation of the implication, from the ceiling inequality rather than from the code path:
     *      breach means covUtil >= threshold and the config requires threshold > WAD, so covUtil > WAD. A covUtil
     *      of 0 (the minCoverage == 0 or exposure == 0 edges) cannot exceed WAD, and jtEff > 0 excludes the
     *      uint256-max edge, so on a breach covUtil is the real ratio ceil(exposure * minCov / jtEff). Since
     *      ceil(a/b) <= WAD iff a <= WAD*b, covUtil > WAD forces exposure * minCov > WAD * jtEff. The config also
     *      requires minCov < WAD, so exposure * WAD > exposure * minCov > WAD * jtEff, and dividing by WAD gives
     *      exposure > jtEff. Intuition: breaching a >100% threshold at a <100% coverage requirement is only
     *      possible when the exposure being covered has outgrown the junior buffer covering it
     */
    function check_liquidationBreachImpliesCoveredExposureExceedsJuniorBuffer(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        bool jtCoinvested,
        uint256 minCoverageWAD,
        uint256 coverageLiquidationUtilizationWAD
    )
        external
        pure
    {
        // The suite-wide NAV domain and the accountant's validated config range (minCoverage < WAD, threshold > WAD)
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(minCoverageWAD < WAD);
        vm.assume(coverageLiquidationUtilizationWAD > WAD);

        // The coverage utilization the checkpoint would carry for these fields is the production computation itself
        uint256 coverageUtilizationWAD =
            UtilizationLogic._computeCoverageUtilization(toNAVUnits(stRaw), toNAVUnits(jtRaw), jtCoinvested, minCoverageWAD, toNAVUnits(jtEff));

        // Breach with a live junior buffer: the exact precondition under which the bonus math reaches its divisions
        if (coverageUtilizationWAD >= coverageLiquidationUtilizationWAD && jtEff > 0) {
            // Covered exposure includes the junior leg only when the junior tranche shares senior's downside
            uint256 totalCoveredExposure = jtCoinvested ? stRaw + jtRaw : stRaw;
            // The hand-derived consequence: exposure > jtEff, so exposure - jtEff >= 1 wei (case 1 denominator) and,
            // since jtEff > 0, the case 2 denominator (exposure - jtEff when coinvested, exposure otherwise) is also >= 1 wei
            assert(totalCoveredExposure > jtEff);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                    TOTALITY ON REACHABLE SYNCED STATES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The self-liquidation bonus computation never reverts on any reachable synced state: breach or no
     *         breach, both co-investment modes, both denominator cases, any bonus rate up to WAD, and any redeeming
     *         user claim in the domain. Reachability is the accountant's own guarantees, imposed as constraints
     *         rather than assumed from the code: NAV conservation (stEff + jtEff == stRaw + jtRaw holds at every
     *         committed sync), a checkpoint coverage utilization that is the production utilization of those same
     *         fields, and the validated config range (minCoverage < WAD, liquidation threshold > WAD)
     * @dev Why totality is non-obvious and worth proving: the bonus math contains two unchecked denominator
     *      subtractions (exposure - jtEff, and exposure - (coinvested ? jtEff : 0)) that would underflow or divide
     *      by zero if a breach state with exposure <= jtEff were reachable, and the claim decomposition subtracts
     *      raw from effective NAVs, which only conservation keeps from underflowing. A revert here would freeze ST
     *      redemptions exactly when the market is in liquidation and exits matter most
     */
    function check_applySeniorTrancheSelfLiquidationBonusNeverRevertsOnReachableBreachStates(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 jtEff,
        bool jtCoinvested,
        uint256 minCoverageWAD,
        uint256 coverageLiquidationUtilizationWAD,
        uint64 stSelfLiquidationBonusWAD,
        uint256 userStAssets,
        uint256 userJtAssets,
        uint256 userNAV
    )
        external
    {
        // The suite-wide NAV domain for the checkpoint NAVs and the redeeming user's claims
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && stEff <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userJtAssets <= MAX_NAV && userNAV <= MAX_NAV);
        // NAV conservation: the loss waterfall only reapportions value between the tranches, never creates or destroys it
        vm.assume(stEff + jtEff == stRaw + jtRaw);
        // The accountant's validated config range and the full bonus rate range
        vm.assume(minCoverageWAD < WAD);
        vm.assume(coverageLiquidationUtilizationWAD > WAD);
        vm.assume(stSelfLiquidationBonusWAD <= WAD);

        // The checkpoint coverage utilization a synced state carries is the production utilization of its own
        // fields, never a free variable: this ties the breach comparison to states a sync can actually commit
        uint256 coverageUtilizationWAD =
            UtilizationLogic._computeCoverageUtilization(toNAVUnits(stRaw), toNAVUnits(jtRaw), jtCoinvested, minCoverageWAD, toNAVUnits(jtEff));

        SyncedAccountingState memory state;
        state.stRawNAV = toNAVUnits(stRaw);
        state.jtRawNAV = toNAVUnits(jtRaw);
        state.stEffectiveNAV = toNAVUnits(stEff);
        state.jtEffectiveNAV = toNAVUnits(jtEff);
        state.jtCoinvested = jtCoinvested;
        state.minCoverageWAD = minCoverageWAD;
        state.coverageUtilizationWAD = coverageUtilizationWAD;
        state.coverageLiquidationUtilizationWAD = coverageLiquidationUtilizationWAD;

        // The redeeming ST user's claims (the harness converts tranche units to NAV units 1:1)
        AssetClaims memory stUserClaims;
        stUserClaims.stAssets = toTrancheUnits(userStAssets);
        stUserClaims.jtAssets = toTrancheUnits(userJtAssets);
        stUserClaims.nav = toNAVUnits(userNAV);

        sll.setSelfLiquidationBonusWAD(stSelfLiquidationBonusWAD);

        // Totality: no reachable state may make the bonus computation revert, across the no-breach early return,
        // the zero-buffer and zero-claim early returns, and both U-neutral denominator cases at both co-investment values
        try this.applyBonusWrapped(state, stUserClaims) returns (AssetClaims memory, NAV_UNIT) { }
        catch {
            assert(false);
        }
    }
}
