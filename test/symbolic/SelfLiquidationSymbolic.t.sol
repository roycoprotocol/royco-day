// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { AssetClaims, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { UtilizationLogic } from "../../src/libraries/logic/UtilizationLogic.sol";
import { SelfLiquidationHarness } from "../mocks/SelfLiquidationHarness.sol";

/**
 * @title SelfLiquidationSymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the senior tranche self-liquidation bonus. The
 *         load-bearing chain: on every reachable liquidation-breach state the covered exposure strictly exceeds
 *         the junior buffer, which makes both coverage-utilization-neutral bonus denominators positive, which
 *         makes the bonus computation total (never reverts), so a redeeming senior LP can always exit a market
 *         that is in liquidation. Around that chain: the below-threshold gate is a strict identity, the bonus is
 *         the minimum of the configured rate slice, the whole junior buffer, and the coverage-neutral cap, the
 *         cap itself is the exactly floored buffer-scaled slice in both sourcing cases and both co-investment
 *         modes, the paid bonus never increases coverage utilization (the anti-bank-run invariant, stated
 *         cross-multiplied with no division), sourcing draws JT's senior-backed claim before its self-backed
 *         claim while conserving the bonus, breach states with no junior buffer or no weighted senior claim pay
 *         nothing, and a configured rate above 100% provably pays out more than the NAV being redeemed (pinned
 *         as a finding candidate)
 * @dev Run with `forge test --symbolic --match-path test/symbolic/SelfLiquidationSymbolic.t.sol`. Functions
 *      prefixed check_ are discovered only under --symbolic. Domain: NAVs and user claims up to 1e30 NAV wei
 *      (one trillion whole 18-decimal tokens, beyond any underwritable market), minCoverage below WAD and
 *      liquidation threshold above WAD (the accountant's validated config range, both strict), bonus rate the
 *      full uint64 range the setter accepts. The harness converts tranche units to NAV units 1:1 so every
 *      property stays branch-local to this library. Expected values are derived independently: floors as plain
 *      checked multiply-and-divide or as fresh values constrained by their two-sided product brackets (products
 *      cap near 2e60, far below 2^256), never by re-running the production mulDiv as its own expectation.
 *      Checkpoints obey NAV conservation (enforced at every accountant commit) and breach-pinned checks consume
 *      the exposure-exceeds-buffer implication proven by the headline check below as their reachable-state
 *      envelope
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
                            EXTERNAL WRAPPER AND BUILDERS
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

    /// @dev Builds the slice of the synced state the bonus computation reads: the four marked NAVs, the
    ///      co-investment flag, and the checkpoint utilization pair compared by the liquidation gate
    function _syncedState(
        uint256 _stRaw,
        uint256 _jtRaw,
        uint256 _stEff,
        uint256 _jtEff,
        bool _jtCoinvested,
        uint256 _covUtilWAD,
        uint256 _liqThreshWAD
    )
        internal
        pure
        returns (SyncedAccountingState memory state)
    {
        state.stRawNAV = toNAVUnits(_stRaw);
        state.jtRawNAV = toNAVUnits(_jtRaw);
        state.stEffectiveNAV = toNAVUnits(_stEff);
        state.jtEffectiveNAV = toNAVUnits(_jtEff);
        state.jtCoinvested = _jtCoinvested;
        state.coverageUtilizationWAD = _covUtilWAD;
        state.coverageLiquidationUtilizationWAD = _liqThreshWAD;
    }

    /// @dev Builds the redeeming senior LP's claims (the harness converts tranche units to NAV units 1:1)
    function _userClaims(uint256 _stAssets, uint256 _jtAssets, uint256 _nav) internal pure returns (AssetClaims memory claims) {
        claims.stAssets = toTrancheUnits(_stAssets);
        claims.jtAssets = toTrancheUnits(_jtAssets);
        claims.nav = toNAVUnits(_nav);
    }

    /// @dev JT's cross-tranche claim on senior raw NAV, derived independently as the saturating excess of JT's
    ///      entitlement over its own pool (the only decomposition output the bonus sourcing reads)
    function _jtClaimOnSTRawNAV(uint256 _jtRaw, uint256 _jtEff) internal pure returns (uint256) {
        return _jtEff > _jtRaw ? _jtEff - _jtRaw : 0;
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
     *      exposure > jtEff. Both strict config bounds are load-bearing: at minCov == WAD or threshold == WAD the
     *      argument collapses. Intuition: breaching a >100% threshold at a <100% coverage requirement is only
     *      possible when the exposure being covered has outgrown the junior buffer covering it. Every other
     *      breach-pinned check in this file consumes this implication as its reachable-state envelope
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
            // The hand-derived consequence: exposure > jtEff, so both unchecked denominators are at least 1 wei
            assert(totalCoveredExposure > jtEff);
            // Stated directly on both denominators: the senior-sourced case divides by exposure - jtEff, and the
            // mixed-sourced case divides by exposure minus (jtEff only when co-invested, which is the same
            // subtraction, or nothing, in which case the whole exposure is the divisor and exceeds jtEff >= 1)
            assert(totalCoveredExposure - jtEff >= 1);
            assert(totalCoveredExposure - (jtCoinvested ? jtEff : 0) >= 1);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                    TOTALITY ON REACHABLE SYNCED STATES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The self-liquidation bonus computation never reverts on any reachable synced state: breach or no
     *         breach, both co-investment modes, both denominator cases, any bonus rate the uint64 setter accepts
     *         (including rates above 100%), and any redeeming user claim in the domain. Reachability is the
     *         accountant's own guarantees, imposed as constraints rather than assumed from the code: NAV
     *         conservation (stEff + jtEff == stRaw + jtRaw holds at every committed sync), a checkpoint coverage
     *         utilization that is the production utilization of those same fields, and the validated config
     *         range (minCoverage < WAD, liquidation threshold > WAD)
     * @dev Why totality is non-obvious and worth proving: the bonus math contains two unchecked denominator
     *      subtractions (exposure - jtEff, and exposure - (coinvested ? jtEff : 0)) that would underflow or divide
     *      by zero if a breach state with exposure <= jtEff were reachable, and the claim decomposition subtracts
     *      raw from effective NAVs, which only conservation keeps from underflowing. A revert here would freeze ST
     *      redemptions exactly when the market is in liquidation and exits matter most. The rate spans the full
     *      uint64 range because the setter accepts it: the desired slice can then exceed the redeemed NAV, but the
     *      computation stays total (the value consequence is pinned by the rate-above-WAD finding check below)
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
        // The accountant's validated config range, both bounds strict
        vm.assume(minCoverageWAD < WAD);
        vm.assume(coverageLiquidationUtilizationWAD > WAD);

        // The checkpoint coverage utilization a synced state carries is the production utilization of its own
        // fields, never a free variable: this ties the breach comparison to states a sync can actually commit
        uint256 coverageUtilizationWAD =
            UtilizationLogic._computeCoverageUtilization(toNAVUnits(stRaw), toNAVUnits(jtRaw), jtCoinvested, minCoverageWAD, toNAVUnits(jtEff));

        SyncedAccountingState memory state =
            _syncedState(stRaw, jtRaw, stEff, jtEff, jtCoinvested, coverageUtilizationWAD, coverageLiquidationUtilizationWAD);
        sll.setSelfLiquidationBonusWAD(stSelfLiquidationBonusWAD);

        // Totality: no reachable state may make the bonus computation revert, across the no-breach early return,
        // the zero-buffer and zero-claim early returns, and both U-neutral denominator cases at both co-investment values
        try this.applyBonusWrapped(state, _userClaims(userStAssets, userJtAssets, userNAV)) returns (AssetClaims memory, NAV_UNIT) { }
        catch {
            assert(false);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                    BELOW THE THRESHOLD THE BONUS IS AN IDENTITY
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Below the liquidation threshold the bonus computation is a strict identity: zero bonus, and every
     *         field of the redeeming user's claims (senior assets, junior assets, LT assets, ST shares, and NAV)
     *         passes through untouched
     * @dev Economic why: the bonus is an emergency delevering incentive funded out of the junior buffer, so in
     *      any healthy market it must not exist at all. A single wei of bonus below the threshold would be a
     *      standing transfer from junior to senior holders on every ordinary redemption. The gate compares the
     *      checkpoint utilization against the configured threshold before touching any arithmetic, so this check
     *      leaves both values symbolic with only their ordering pinned
     */
    function check_belowLiquidationThresholdRemitsNoBonusAndPassesClaimsThroughUntouched(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 jtEff,
        bool jtCoinvested,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint64 rate,
        uint256 userStAssets,
        uint256 userJtAssets,
        uint256 userLtAssets,
        uint256 userStShares,
        uint256 userNAV
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && stEff <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userJtAssets <= MAX_NAV && userNAV <= MAX_NAV);
        vm.assume(userLtAssets <= MAX_NAV && userStShares <= MAX_NAV);
        // The one pinned branch: the checkpoint utilization sits strictly below the liquidation threshold
        vm.assume(covUtilWAD < liqThreshWAD);

        AssetClaims memory userClaims = _userClaims(userStAssets, userJtAssets, userNAV);
        userClaims.ltAssets = toTrancheUnits(userLtAssets);
        userClaims.stShares = userStShares;

        sll.setSelfLiquidationBonusWAD(rate);
        (AssetClaims memory out, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, jtCoinvested, covUtilWAD, liqThreshWAD), userClaims);

        // No bonus, and the claims struct is returned untouched in every field
        assert(toUint256(bonus) == 0);
        assert(toUint256(out.stAssets) == userStAssets);
        assert(toUint256(out.jtAssets) == userJtAssets);
        assert(toUint256(out.ltAssets) == userLtAssets);
        assert(out.stShares == userStShares);
        assert(toUint256(out.nav) == userNAV);
    }

    /*//////////////////////////////////////////////////////////////////////
                    THE BONUS IS THE MINIMUM OF THREE CAPS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice When the configured rate slice of the redeemed NAV is the smallest of the three caps (rate slice,
     *         whole junior buffer, coverage-neutral cap), the paid bonus is exactly that slice:
     *         floor(redeemedNAV * rate / WAD), derived here as a plain checked multiply-and-divide
     * @dev Economic why: the rate is the issuer's chosen incentive strength, so when neither the junior buffer
     *      nor coverage neutrality binds, the redeemer must receive exactly the advertised fraction of the NAV
     *      they are pulling out, floored in favor of the junior holders funding it. The senior-sourced cap case
     *      is pinned (the cap value itself is owned by the case-exact checks below) and the market is not
     *      co-invested, so the covered exposure is the senior pool alone. Exposure exceeding the buffer is the
     *      reachable-breach envelope proven by the headline implication check in this file
     */
    function check_bonusBindsToTheConfiguredRateSliceWhenItIsTheSmallestCap(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint64 rate,
        uint256 userStAssets,
        uint256 userNAV
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userNAV <= MAX_NAV);
        // A live junior buffer and a conserving checkpoint: senior's effective NAV is what the two pools hold
        // minus junior's entitlement, so conservation pins it rather than leaving it free
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        // Breach at a validated threshold, and the reachable-breach envelope: exposure (the senior pool alone,
        // since the market is not co-invested) strictly exceeds the junior buffer
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);
        vm.assume(stRaw > jtEff);
        // A live weighted claim so the neutral cap's division is actually reached
        vm.assume(1 <= userStAssets);

        // Independently derived caps, plain checked arithmetic (products cap near 2e60, well inside uint256)
        uint256 desired = (userNAV * uint256(rate)) / WAD;
        uint256 seniorSourcedCap = (userStAssets * jtEff) / (stRaw - jtEff);
        // Pin the senior-sourced cap case: the cap fits inside JT's claim on senior raw NAV
        vm.assume(seniorSourcedCap <= _jtClaimOnSTRawNAV(jtRaw, jtEff));
        // Pin the binding term: the rate slice is the smallest of the three caps
        vm.assume(desired <= jtEff && desired <= seniorSourcedCap);

        sll.setSelfLiquidationBonusWAD(rate);
        (AssetClaims memory out, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, false, covUtilWAD, liqThreshWAD), _userClaims(userStAssets, 0, userNAV));

        // The paid bonus is exactly the advertised floored rate slice, and it lands in the redeemer's NAV
        assert(toUint256(bonus) == desired);
        assert(toUint256(out.nav) == userNAV + desired);
    }

    /**
     * @notice When the whole junior effective NAV is the smallest of the three caps, the paid bonus is exactly
     *         the junior buffer: the redeemer sweeps everything the junior tranche still controls, and not a wei
     *         more can ever be sourced
     * @dev Economic why: the bonus is carved out of junior-controlled NAV, so the junior buffer is a hard wall.
     *      When the configured slice and the coverage-neutral cap both sit at or above it, the redeemer takes the
     *      buffer to zero exactly, which is the boundary the bank-run bound below generalizes. Senior-sourced cap
     *      case pinned, market not co-invested, breach envelope as proven by the headline implication check
     */
    function check_bonusBindsToTheWholeJuniorBufferWhenItIsTheSmallestCap(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint64 rate,
        uint256 userStAssets,
        uint256 userNAV
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userNAV <= MAX_NAV);
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);
        vm.assume(stRaw > jtEff);
        vm.assume(1 <= userStAssets);

        uint256 desired = (userNAV * uint256(rate)) / WAD;
        uint256 seniorSourcedCap = (userStAssets * jtEff) / (stRaw - jtEff);
        vm.assume(seniorSourcedCap <= _jtClaimOnSTRawNAV(jtRaw, jtEff));
        // Pin the binding term: the junior buffer is the smallest of the three caps
        vm.assume(jtEff <= desired && jtEff <= seniorSourcedCap);

        sll.setSelfLiquidationBonusWAD(rate);
        (AssetClaims memory out, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, false, covUtilWAD, liqThreshWAD), _userClaims(userStAssets, 0, userNAV));

        // The paid bonus is exactly the whole junior buffer, credited to the redeemer's NAV
        assert(toUint256(bonus) == jtEff);
        assert(toUint256(out.nav) == userNAV + jtEff);
    }

    /**
     * @notice When the coverage-utilization-neutral cap is the smallest of the three caps, the paid bonus is
     *         exactly that cap: the redeemer is stopped at the largest bonus that leaves the market's leverage
     *         no worse for the LPs who stay
     * @dev Economic why: paying past this cap would raise coverage utilization with every exiting senior LP,
     *      handing early exiters a bonus financed by degrading the coverage of everyone behind them, which is the
     *      bank-run dynamic the cap exists to kill. Senior-sourced case pinned with the cap derived as a plain
     *      floored multiply-and-divide, market not co-invested, breach envelope as proven by the headline check
     */
    function check_bonusBindsToTheCoverageNeutralCapWhenItIsTheSmallestCap(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint64 rate,
        uint256 userStAssets,
        uint256 userNAV
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userNAV <= MAX_NAV);
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);
        vm.assume(stRaw > jtEff);
        vm.assume(1 <= userStAssets);

        uint256 desired = (userNAV * uint256(rate)) / WAD;
        uint256 seniorSourcedCap = (userStAssets * jtEff) / (stRaw - jtEff);
        vm.assume(seniorSourcedCap <= _jtClaimOnSTRawNAV(jtRaw, jtEff));
        // Pin the binding term: the coverage-neutral cap is the smallest of the three caps
        vm.assume(seniorSourcedCap <= desired && seniorSourcedCap <= jtEff);

        sll.setSelfLiquidationBonusWAD(rate);
        (AssetClaims memory out, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, false, covUtilWAD, liqThreshWAD), _userClaims(userStAssets, 0, userNAV));

        // The paid bonus is exactly the leverage-neutral maximum
        assert(toUint256(bonus) == seniorSourcedCap);
        assert(toUint256(out.nav) == userNAV + seniorSourcedCap);
    }

    /*//////////////////////////////////////////////////////////////////////
                    THE BONUS NEVER EXCEEDS THE JUNIOR BUFFER
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On every path (below or above the liquidation threshold, both co-investment modes, both sourcing
     *         cases, any uint64 rate) the paid bonus never exceeds the junior effective NAV, and the redeemer's
     *         NAV grows by exactly the reported bonus
     * @dev Economic why: the bonus is sourced from NAV the junior tranche controls, so a bonus above the junior
     *      buffer would mint senior claims out of nothing and break conservation at the very next sync. This is
     *      the standalone bank-run safety bound: no single redemption, however large its claims or rate, can pull
     *      more than the junior tranche has left. Exposure exceeding the buffer whenever the gate is breached is
     *      the reachable-breach envelope from the headline implication check, imposed here across both gate
     *      outcomes at once (the senior pool alone already exceeding the buffer covers both co-investment modes,
     *      since co-investing only adds the junior pool to the exposure)
     */
    function check_bonusNeverExceedsTheJuniorEffectiveNAVBuffer(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        bool jtCoinvested,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint64 rate,
        uint256 userStAssets,
        uint256 userJtAssets,
        uint256 userNAV
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userJtAssets <= MAX_NAV && userNAV <= MAX_NAV);
        // A conserving checkpoint pins senior's effective NAV
        vm.assume(jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        // A validated threshold, and the reachable-state envelope across both gate outcomes: either the market
        // is healthy (below threshold), or it is breached and the senior pool alone outgrew the junior buffer
        // (the headline implication check proves exposure > jtEff on every reachable breach, and stRaw > jtEff
        // is the sub-envelope that covers both co-investment modes at once)
        vm.assume(liqThreshWAD > WAD);
        vm.assume(covUtilWAD < liqThreshWAD || stRaw > jtEff);

        sll.setSelfLiquidationBonusWAD(rate);
        (AssetClaims memory out, NAV_UNIT bonus) = sll.applyBonus(
            _syncedState(stRaw, jtRaw, stEff, jtEff, jtCoinvested, covUtilWAD, liqThreshWAD), _userClaims(userStAssets, userJtAssets, userNAV)
        );

        // The bank-run wall: the bonus can sweep at most the junior buffer, never past it
        assert(toUint256(bonus) <= jtEff);
        // And the redeemer is credited exactly the reported bonus, no more and no less
        assert(toUint256(out.nav) == userNAV + toUint256(bonus));
    }

    /*//////////////////////////////////////////////////////////////////////
                    SOURCING DRAWS SENIOR-BACKED CLAIMS FIRST
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A nonzero bonus is sourced senior-assets-first and conserved exactly: the senior-asset leg is
     *         min(bonus, JT's claim on senior raw NAV), the junior-asset leg is the remainder, the remainder
     *         always fits inside JT's self-backed claim, the redeemer's NAV grows by exactly the bonus, and the
     *         bonus path returns a claims struct whose LT-asset and ST-share legs are zeroed regardless of what
     *         the input carried
     * @dev Economic why: senior-backed claims are the cheaper source per unit of coverage relief (drawing them
     *      shrinks the covered exposure itself), so they are drained before JT's own pool is touched, and the
     *      two legs must sum to the reported bonus or value would be minted or burned in transit. The remainder
     *      fitting in the self-backed claim follows from the bonus being capped at the junior effective NAV,
     *      which under conservation is exactly the sum of JT's two claims. The zeroed LT legs pin the fresh
     *      output struct the bonus path builds: a redeeming senior claim never carries LT legs in production,
     *      but any caller that passed them here would see them silently dropped, so the behavior is pinned
     *      exactly as built
     */
    function check_bonusSourcingDrawsSeniorBackedClaimsFirstAndConservesTheBonus(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        bool jtCoinvested,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint64 rate,
        uint256 userStAssets,
        uint256 userJtAssets,
        uint256 userLtAssets,
        uint256 userStShares,
        uint256 userNAV
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userJtAssets <= MAX_NAV && userNAV <= MAX_NAV);
        // Nonzero LT legs on the input, so the fresh-struct zeroing is actually observable
        vm.assume(1 <= userLtAssets && userLtAssets <= MAX_NAV && 1 <= userStShares && userStShares <= MAX_NAV);
        // A conserving checkpoint with a live junior buffer
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        // Breach at a validated threshold, on the reachable-breach envelope (the senior pool alone exceeding the
        // buffer covers both co-investment modes, per the headline implication check)
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);
        vm.assume(stRaw > jtEff);

        AssetClaims memory userClaims = _userClaims(userStAssets, userJtAssets, userNAV);
        userClaims.ltAssets = toTrancheUnits(userLtAssets);
        userClaims.stShares = userStShares;

        sll.setSelfLiquidationBonusWAD(rate);
        (AssetClaims memory out, NAV_UNIT bonusNAV) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, jtCoinvested, covUtilWAD, liqThreshWAD), userClaims);

        // Pin the nonzero-bonus regime this property is about (the zero-bonus paths are identity, owned by the
        // gate and early-out checks)
        uint256 bonus = toUint256(bonusNAV);
        vm.assume(bonus > 0);

        // JT's two claims, derived independently: the cross claim is the saturating excess of its entitlement
        // over its own pool, and under conservation the self-backed claim is the rest of the entitlement
        uint256 jtClaimOnST = _jtClaimOnSTRawNAV(jtRaw, jtEff);
        uint256 jtClaimOnSelf = jtEff - jtClaimOnST;

        // Senior-assets-first sourcing: the senior leg is everything the cross claim can supply, capped at the bonus
        uint256 fromST = bonus < jtClaimOnST ? bonus : jtClaimOnST;
        assert(toUint256(out.stAssets) == userStAssets + fromST);
        // The junior leg is exactly the remainder, and it always fits inside JT's self-backed claim because the
        // bonus was already capped at the junior effective NAV, which is the sum of the two claims
        uint256 fromJT = bonus - fromST;
        assert(toUint256(out.jtAssets) == userJtAssets + fromJT);
        assert(fromJT <= jtClaimOnSelf);
        // The bonus is conserved into the redeemer's NAV exactly
        assert(toUint256(out.nav) == userNAV + bonus);
        // The bonus path builds a fresh output struct: the input's LT-asset and ST-share legs are dropped
        assert(toUint256(out.ltAssets) == 0);
        assert(out.stShares == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
            THE SENIOR-SOURCED NEUTRAL CAP IS AN EXACT FLOORED SLICE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Without co-investment, when the senior-sourced cap fits inside JT's claim on senior raw NAV and is
     *         the binding term of the min, the paid bonus is exactly floor(weightedClaim * jtEff / (stRaw - jtEff)),
     *         pinned by its two-sided product bracket: bonus * (stRaw - jtEff) <= weightedClaim * jtEff
     *         < (bonus + 1) * (stRaw - jtEff)
     * @dev Independent derivation of the cap: post-redemption utilization must not exceed the pre-redemption
     *      one, and with the whole bonus drawn from JT's senior-backed claim both the covered exposure and the
     *      junior buffer shrink by the bonus, so neutrality solves to bonus <= weightedClaim * jtEff / (exposure
     *      - jtEff), floored against the exiting LP. Without co-investment the exposure is the senior pool and
     *      the weighted claim is the user's senior-asset claim alone. The bracket is stated with a fresh symbolic
     *      value rather than by re-running the production division, and the denominator's positivity comes from
     *      the reachable-breach envelope (asserted below rather than silently assumed away). The rate is pinned
     *      to 100% so the configured slice equals the redeemed NAV and only the buffer or the cap can bind (the
     *      rate interaction is owned by the min-of-three checks above)
     */
    function check_seniorSourcedNeutralCapIsTheFlooredBufferScaledSliceWithoutCoinvestment(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint256 userStAssets,
        uint256 userNAV,
        uint256 cap
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userNAV <= MAX_NAV);
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);
        vm.assume(stRaw > jtEff);
        vm.assume(1 <= userStAssets);
        // The denominator positivity the breach envelope guarantees, stated explicitly on the divisor itself
        uint256 excessExposure = stRaw - jtEff;
        assert(excessExposure >= 1);

        // The expected cap as a fresh symbolic value pinned only by its two-sided floor bracket
        vm.assume(cap * excessExposure <= userStAssets * jtEff);
        vm.assume(userStAssets * jtEff < (cap + 1) * excessExposure);
        // Pin the senior-sourced case: the cap fits inside JT's claim on senior raw NAV
        vm.assume(cap <= _jtClaimOnSTRawNAV(jtRaw, jtEff));
        // Pin the cap as the binding term: at a 100% rate the configured slice is the whole redeemed NAV
        vm.assume(cap <= userNAV && cap <= jtEff);

        sll.setSelfLiquidationBonusWAD(uint64(WAD));
        (, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, false, covUtilWAD, liqThreshWAD), _userClaims(userStAssets, 0, userNAV));

        // The paid bonus is exactly the bracketed floor
        assert(toUint256(bonus) == cap);
    }

    /**
     * @notice With co-investment, when the senior-sourced cap fits inside JT's claim on senior raw NAV and is
     *         the binding term of the min, the paid bonus is exactly
     *         floor((userStAssets + userJtAssets) * jtEff / (stRaw + jtRaw - jtEff)), pinned by its two-sided
     *         product bracket
     * @dev Independent derivation: with co-investment the junior pool is inside the covered exposure, so the
     *      exposure is both pools together and the user's junior-asset claim joins the weighted claim, while the
     *      denominator (exposure minus buffer) becomes, under conservation, exactly the senior effective NAV.
     *      Same fresh-value bracket encoding, denominator positivity from the breach envelope, rate pinned to
     *      100% so only the buffer or the cap can bind
     */
    function check_seniorSourcedNeutralCapIsTheFlooredBufferScaledSliceWithCoinvestment(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint256 userStAssets,
        uint256 userJtAssets,
        uint256 userNAV,
        uint256 cap
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userJtAssets <= MAX_NAV && userNAV <= MAX_NAV);
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);
        // The reachable-breach envelope on the co-invested exposure: both pools together exceed the buffer
        vm.assume(stRaw + jtRaw > jtEff);
        // A live weighted claim spanning both legs
        uint256 weightedClaim = userStAssets + userJtAssets;
        vm.assume(1 <= weightedClaim);
        // Under conservation the excess exposure equals the senior effective NAV exactly
        uint256 excessExposure = stRaw + jtRaw - jtEff;
        assert(excessExposure == stEff && excessExposure >= 1);

        // The expected cap as a fresh symbolic value pinned only by its two-sided floor bracket
        vm.assume(cap * excessExposure <= weightedClaim * jtEff);
        vm.assume(weightedClaim * jtEff < (cap + 1) * excessExposure);
        vm.assume(cap <= _jtClaimOnSTRawNAV(jtRaw, jtEff));
        vm.assume(cap <= userNAV && cap <= jtEff);

        sll.setSelfLiquidationBonusWAD(uint64(WAD));
        (, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, true, covUtilWAD, liqThreshWAD), _userClaims(userStAssets, userJtAssets, userNAV));

        assert(toUint256(bonus) == cap);
    }

    /*//////////////////////////////////////////////////////////////////////
            THE MIXED-SOURCED NEUTRAL CAP ADDS HEADROOM ONLY UNCOINVESTED
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Without co-investment, when the senior-sourced cap overshoots JT's claim on senior raw NAV, the
     *         cap is recomputed for mixed sourcing and the paid bonus is exactly
     *         floor((userStAssets + jtClaimOnST) * jtEff / stRaw): the numerator gains the whole senior-backed
     *         claim as headroom and the denominator becomes the whole covered exposure
     * @dev Independent derivation: once JT's senior-backed claim is exhausted, the remainder is drawn from JT's
     *      own pool. Without co-investment that pool is outside the covered exposure, so a junior-sourced wei
     *      shrinks only the buffer and not the exposure, making it more expensive per unit of neutrality, which
     *      is exactly why the cheaper senior-backed claim is spent first and appears as added numerator headroom.
     *      The denominator is the full exposure because junior-sourced draws no longer cancel out of it. The
     *      senior-sourced cap is itself pinned by a fresh-value bracket (never by re-running the production
     *      division) only to select the overshoot branch. Rate pinned to 100% so only the buffer or the cap can
     *      bind
     */
    function check_mixedSourcedNeutralCapAddsSeniorClaimHeadroomWithoutCoinvestment(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint256 userStAssets,
        uint256 userNAV,
        uint256 seniorSourcedCap,
        uint256 cap
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userNAV <= MAX_NAV);
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);
        vm.assume(stRaw > jtEff);
        vm.assume(1 <= userStAssets);
        uint256 jtClaimOnST = _jtClaimOnSTRawNAV(jtRaw, jtEff);

        // The senior-sourced cap as a fresh bracketed value, used only to pin the overshoot branch
        vm.assume(seniorSourcedCap * (stRaw - jtEff) <= userStAssets * jtEff);
        vm.assume(userStAssets * jtEff < (seniorSourcedCap + 1) * (stRaw - jtEff));
        vm.assume(seniorSourcedCap > jtClaimOnST);

        // The mixed-sourced cap as a fresh symbolic value pinned by its two-sided floor bracket: numerator
        // gains the senior-backed claim, denominator is the whole exposure (the senior pool, uncoinvested)
        vm.assume(cap * stRaw <= (userStAssets + jtClaimOnST) * jtEff);
        vm.assume((userStAssets + jtClaimOnST) * jtEff < (cap + 1) * stRaw);
        // Pin the cap as the binding term of the min at a 100% rate
        vm.assume(cap <= userNAV && cap <= jtEff);

        sll.setSelfLiquidationBonusWAD(uint64(WAD));
        (, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, false, covUtilWAD, liqThreshWAD), _userClaims(userStAssets, 0, userNAV));

        assert(toUint256(bonus) == cap);
    }

    /**
     * @notice With co-investment, when the senior-sourced cap overshoots JT's claim on senior raw NAV, the
     *         mixed-sourced recomputation changes nothing: the paid bonus is still exactly
     *         floor(weightedClaim * jtEff / (exposure - jtEff)), because a co-invested junior pool sits inside
     *         the covered exposure, making junior-sourced and senior-sourced weis equally cheap per unit of
     *         neutrality, so no headroom is added and no denominator changes
     * @dev Independent derivation: with co-investment every sourced wei, from either claim, shrinks both the
     *      exposure and the buffer by one, so the neutrality algebra is identical across sourcing and the two
     *      cases collapse to the same floored slice. Fresh-value bracket encoding over the shared denominator,
     *      overshoot branch pinned, rate pinned to 100%
     */
    function check_mixedSourcedNeutralCapKeepsTheSameSliceWithCoinvestment(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint256 userStAssets,
        uint256 userJtAssets,
        uint256 userNAV,
        uint256 cap
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userJtAssets <= MAX_NAV && userNAV <= MAX_NAV);
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);
        vm.assume(stRaw + jtRaw > jtEff);
        uint256 weightedClaim = userStAssets + userJtAssets;
        vm.assume(1 <= weightedClaim);
        uint256 excessExposure = stRaw + jtRaw - jtEff;

        // One fresh bracketed value serves both cases, since with co-investment they share numerator and denominator
        vm.assume(cap * excessExposure <= weightedClaim * jtEff);
        vm.assume(weightedClaim * jtEff < (cap + 1) * excessExposure);
        // Pin the overshoot branch: the senior-backed claim cannot carry the whole cap
        vm.assume(cap > _jtClaimOnSTRawNAV(jtRaw, jtEff));
        // Pin the cap as the binding term of the min at a 100% rate
        vm.assume(cap <= userNAV && cap <= jtEff);

        sll.setSelfLiquidationBonusWAD(uint64(WAD));
        (, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, true, covUtilWAD, liqThreshWAD), _userClaims(userStAssets, userJtAssets, userNAV));

        assert(toUint256(bonus) == cap);
    }

    /*//////////////////////////////////////////////////////////////////////
            THE BONUS NEVER INCREASES COVERAGE UTILIZATION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On the senior-sourced path without co-investment, the paid bonus never increases coverage
     *         utilization, stated cross-multiplied with no division:
     *         fromST * (stRaw - jtEff) + fromJT * stRaw <= jtEff * userStAssets
     * @dev Independent derivation of the inequality: utilization is exposure * minCov / buffer, the redemption
     *      itself removes the user's weighted claim from the exposure, a senior-sourced bonus wei removes one
     *      from both exposure and buffer, and a junior-sourced wei removes one from the buffer only, so
     *      post-utilization <= pre-utilization cross-multiplies to exactly this weighted bound. A violation
     *      would mean each exiting senior LP degrades coverage for those who stay, which is the bank-run
     *      amplifier the cap exists to prevent. The sourcing legs are observed from the output claims, never
     *      recomputed, and the rate spans the full uint64 range since a smaller bonus only slackens the bound
     */
    function check_bonusKeepsCoverageUtilizationFlatOnTheSeniorSourcedPathWithoutCoinvestment(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint64 rate,
        uint256 userStAssets,
        uint256 userNAV,
        uint256 seniorSourcedCap
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userNAV <= MAX_NAV);
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);
        vm.assume(stRaw > jtEff);
        vm.assume(1 <= userStAssets);

        // Pin the senior-sourced case through the fresh bracketed cap value
        vm.assume(seniorSourcedCap * (stRaw - jtEff) <= userStAssets * jtEff);
        vm.assume(userStAssets * jtEff < (seniorSourcedCap + 1) * (stRaw - jtEff));
        vm.assume(seniorSourcedCap <= _jtClaimOnSTRawNAV(jtRaw, jtEff));

        sll.setSelfLiquidationBonusWAD(rate);
        (AssetClaims memory out, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, false, covUtilWAD, liqThreshWAD), _userClaims(userStAssets, 0, userNAV));

        // The two sourcing legs, observed straight off the output claims
        uint256 fromST = toUint256(out.stAssets) - userStAssets;
        uint256 fromJT = toUint256(out.jtAssets);
        assert(fromST + fromJT == toUint256(bonus));

        // The anti-bank-run invariant, cross-multiplied: senior-sourced weis are weighted by the excess
        // exposure, junior-sourced weis by the whole exposure (they shrink only the buffer)
        assert(fromST * (stRaw - jtEff) + fromJT * stRaw <= jtEff * userStAssets);
    }

    /**
     * @notice On the senior-sourced path with co-investment, the paid bonus never increases coverage
     *         utilization, cross-multiplied: (fromST + fromJT) * (exposure - jtEff) <= jtEff * weightedClaim,
     *         with the exposure spanning both pools and the weighted claim spanning both user legs
     * @dev Same derivation as the uncoinvested twin, but with the junior pool inside the exposure every sourced
     *      wei shrinks exposure and buffer alike, so both sourcing legs carry the same weight. Sourcing legs
     *      observed from outputs, rate unconstrained across the full uint64 range
     */
    function check_bonusKeepsCoverageUtilizationFlatOnTheSeniorSourcedPathWithCoinvestment(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint64 rate,
        uint256 userStAssets,
        uint256 userJtAssets,
        uint256 userNAV,
        uint256 seniorSourcedCap
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userJtAssets <= MAX_NAV && userNAV <= MAX_NAV);
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);
        vm.assume(stRaw + jtRaw > jtEff);
        uint256 weightedClaim = userStAssets + userJtAssets;
        vm.assume(1 <= weightedClaim);
        uint256 excessExposure = stRaw + jtRaw - jtEff;

        // Pin the senior-sourced case through the fresh bracketed cap value
        vm.assume(seniorSourcedCap * excessExposure <= weightedClaim * jtEff);
        vm.assume(weightedClaim * jtEff < (seniorSourcedCap + 1) * excessExposure);
        vm.assume(seniorSourcedCap <= _jtClaimOnSTRawNAV(jtRaw, jtEff));

        sll.setSelfLiquidationBonusWAD(rate);
        (AssetClaims memory out, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, true, covUtilWAD, liqThreshWAD), _userClaims(userStAssets, userJtAssets, userNAV));

        uint256 fromST = toUint256(out.stAssets) - userStAssets;
        uint256 fromJT = toUint256(out.jtAssets) - userJtAssets;
        assert(fromST + fromJT == toUint256(bonus));

        // With co-investment every sourced wei carries the same excess-exposure weight
        assert((fromST + fromJT) * excessExposure <= jtEff * weightedClaim);
    }

    /**
     * @notice On the mixed-sourced path without co-investment, the paid bonus never increases coverage
     *         utilization, cross-multiplied: fromST * (stRaw - jtEff) + fromJT * stRaw <= jtEff * userStAssets
     * @dev Same weighted bound as the senior-sourced twin (the invariant does not care which case computed the
     *      cap), with the overshoot branch pinned instead: JT's senior-backed claim cannot carry the whole cap,
     *      so the junior-sourced leg is live and its heavier whole-exposure weight is actually exercised. The
     *      recomputed cap trades each junior-sourced wei at its true, more expensive neutrality price, and this
     *      check proves the trade never tips the balance. Rate unconstrained across the full uint64 range
     */
    function check_bonusKeepsCoverageUtilizationFlatOnTheMixedSourcedPathWithoutCoinvestment(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint64 rate,
        uint256 userStAssets,
        uint256 userNAV,
        uint256 seniorSourcedCap
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userNAV <= MAX_NAV);
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);
        vm.assume(stRaw > jtEff);
        vm.assume(1 <= userStAssets);

        // Pin the overshoot (mixed-sourced) branch through the fresh bracketed senior-sourced cap
        vm.assume(seniorSourcedCap * (stRaw - jtEff) <= userStAssets * jtEff);
        vm.assume(userStAssets * jtEff < (seniorSourcedCap + 1) * (stRaw - jtEff));
        vm.assume(seniorSourcedCap > _jtClaimOnSTRawNAV(jtRaw, jtEff));

        sll.setSelfLiquidationBonusWAD(rate);
        (AssetClaims memory out, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, false, covUtilWAD, liqThreshWAD), _userClaims(userStAssets, 0, userNAV));

        uint256 fromST = toUint256(out.stAssets) - userStAssets;
        uint256 fromJT = toUint256(out.jtAssets);
        assert(fromST + fromJT == toUint256(bonus));

        assert(fromST * (stRaw - jtEff) + fromJT * stRaw <= jtEff * userStAssets);
    }

    /**
     * @notice On the mixed-sourced path with co-investment, the paid bonus never increases coverage
     *         utilization, cross-multiplied: (fromST + fromJT) * (exposure - jtEff) <= jtEff * weightedClaim
     * @dev With co-investment the mixed-sourced recomputation returns the same slice as the senior-sourced case
     *      (both sourcing legs are equally cheap inside the exposure), so this check pins the overshoot branch
     *      and proves the invariant survives the recomputation verbatim. Sourcing legs observed from outputs,
     *      rate unconstrained across the full uint64 range
     */
    function check_bonusKeepsCoverageUtilizationFlatOnTheMixedSourcedPathWithCoinvestment(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint64 rate,
        uint256 userStAssets,
        uint256 userJtAssets,
        uint256 userNAV,
        uint256 seniorSourcedCap
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userJtAssets <= MAX_NAV && userNAV <= MAX_NAV);
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);
        vm.assume(stRaw + jtRaw > jtEff);
        uint256 weightedClaim = userStAssets + userJtAssets;
        vm.assume(1 <= weightedClaim);
        uint256 excessExposure = stRaw + jtRaw - jtEff;

        // Pin the overshoot (mixed-sourced) branch through the fresh bracketed senior-sourced cap
        vm.assume(seniorSourcedCap * excessExposure <= weightedClaim * jtEff);
        vm.assume(weightedClaim * jtEff < (seniorSourcedCap + 1) * excessExposure);
        vm.assume(seniorSourcedCap > _jtClaimOnSTRawNAV(jtRaw, jtEff));

        sll.setSelfLiquidationBonusWAD(rate);
        (AssetClaims memory out, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, true, covUtilWAD, liqThreshWAD), _userClaims(userStAssets, userJtAssets, userNAV));

        uint256 fromST = toUint256(out.stAssets) - userStAssets;
        uint256 fromJT = toUint256(out.jtAssets) - userJtAssets;
        assert(fromST + fromJT == toUint256(bonus));

        assert((fromST + fromJT) * excessExposure <= jtEff * weightedClaim);
    }

    /*//////////////////////////////////////////////////////////////////////
                    ZERO-CAPITAL EARLY OUTS PAY NOTHING
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On a breach with no junior buffer left (jtEff == 0), the bonus is zero and every claim field
     *         passes through untouched, including the LT-asset and ST-share legs
     * @dev Economic why: the bonus is carved from junior-controlled NAV, so an exhausted buffer has nothing to
     *      remit no matter how large the redemption or the configured rate. This is also the one breach state
     *      the exposure-exceeds-buffer envelope does not cover (utilization is reported as the uint256 sentinel,
     *      not a real ratio), so the zero-buffer early out is what keeps the divisions unreachable there.
     *      Conservation forces senior's effective NAV to the whole two-pool total
     */
    function check_breachWithNoJuniorBufferRemitsNoBonusAndPassesClaimsThrough(
        uint256 stRaw,
        uint256 jtRaw,
        bool jtCoinvested,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint64 rate,
        uint256 userStAssets,
        uint256 userJtAssets,
        uint256 userLtAssets,
        uint256 userStShares,
        uint256 userNAV
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && userJtAssets <= MAX_NAV && userNAV <= MAX_NAV);
        vm.assume(userLtAssets <= MAX_NAV && userStShares <= MAX_NAV);
        // Breach at a validated threshold, with the junior buffer fully exhausted
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);
        // Conservation with jtEff == 0: everything both pools hold belongs to the senior tranche
        uint256 stEff = stRaw + jtRaw;

        AssetClaims memory userClaims = _userClaims(userStAssets, userJtAssets, userNAV);
        userClaims.ltAssets = toTrancheUnits(userLtAssets);
        userClaims.stShares = userStShares;

        sll.setSelfLiquidationBonusWAD(rate);
        (AssetClaims memory out, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, 0, jtCoinvested, covUtilWAD, liqThreshWAD), userClaims);

        // Nothing to source from: zero bonus, and the zero-bonus path returns the input claims untouched
        assert(toUint256(bonus) == 0);
        assert(toUint256(out.stAssets) == userStAssets);
        assert(toUint256(out.jtAssets) == userJtAssets);
        assert(toUint256(out.ltAssets) == userLtAssets);
        assert(out.stShares == userStShares);
        assert(toUint256(out.nav) == userNAV);
    }

    /**
     * @notice On a breach without co-investment, a redeemer whose claims are junior-assets-only (no senior-asset
     *         claim) receives no bonus and their claims pass through untouched, however large the junior-asset
     *         claim or the redeemed NAV
     * @dev Economic why: the coverage-neutral cap scales with the redeemer's claim on the covered exposure, and
     *      without co-investment the junior pool is outside that exposure, so a junior-only redemption delevers
     *      nothing and has earned no delevering incentive. Paying it anything would fund exits that do not reduce
     *      the risk the bonus exists to unwind. This is the deliberate design point that the weighted claim, not
     *      the redeemed NAV, prices the bonus
     */
    function check_breachWithNoWeightedClaimRemitsNoBonusForJuniorOnlyClaimsWithoutCoinvestment(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint64 rate,
        uint256 userJtAssets,
        uint256 userNAV
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userNAV <= MAX_NAV);
        // A live junior-asset claim makes the zero-weight outcome non-vacuous
        vm.assume(1 <= userJtAssets && userJtAssets <= MAX_NAV);
        // A conserving checkpoint with a live junior buffer
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);

        sll.setSelfLiquidationBonusWAD(rate);
        // The user's senior-asset claim is zero, so without co-investment the weighted claim is zero
        (AssetClaims memory out, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, false, covUtilWAD, liqThreshWAD), _userClaims(0, userJtAssets, userNAV));

        assert(toUint256(bonus) == 0);
        assert(toUint256(out.stAssets) == 0);
        assert(toUint256(out.jtAssets) == userJtAssets);
        assert(toUint256(out.nav) == userNAV);
    }

    /**
     * @notice On a breach with co-investment, a redeemer with no claim on either pool receives no bonus and
     *         their claims pass through untouched, however large the redeemed NAV or the configured rate
     * @dev Economic why: with co-investment both user legs count toward the weighted claim, so only a claim
     *      that is empty on both legs prices to zero. A redemption that removes no exposure delevers nothing,
     *      and the NAV field alone (which the rate slice is quoted on) buys no bonus without backing claims
     */
    function check_breachWithNoWeightedClaimRemitsNoBonusWithCoinvestment(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint64 rate,
        uint256 userNAV
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userNAV <= MAX_NAV);
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);

        sll.setSelfLiquidationBonusWAD(rate);
        // Both user legs are zero, so the co-invested weighted claim is zero no matter the NAV field
        (AssetClaims memory out, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, true, covUtilWAD, liqThreshWAD), _userClaims(0, 0, userNAV));

        assert(toUint256(bonus) == 0);
        assert(toUint256(out.stAssets) == 0);
        assert(toUint256(out.jtAssets) == 0);
        assert(toUint256(out.nav) == userNAV);
    }

    /*//////////////////////////////////////////////////////////////////////
            FINDING CANDIDATE: A RATE ABOVE 100% OUTPAYS THE REDEEMED NAV
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice PINS A DIVERGENCE. The bonus rate setter accepts any uint64 value with no cap at WAD, and a
     *         configured rate above 100% provably pays a bonus larger than the entire NAV being redeemed: on
     *         this whole pinned sub-domain (rate at least 200%, neither the junior buffer nor the neutral cap
     *         binding) the paid bonus equals floor(redeemedNAV * rate / WAD), which is strictly more than the
     *         redeemed NAV itself
     * @dev Why this is a divergence worth pinning: every other WAD-scaled percentage in the system is validated
     *      to at most 100%, and a bonus exceeding the redemption it rides on stops being a discount-absorption
     *      cushion and becomes a junior-funded payout multiplier on exit size. The other two caps still bound it
     *      (the buffer and coverage neutrality are proven above), so this is a config-validation gap rather than
     *      an accounting hole, but a fat-fingered or malicious rate would silently overpay every self-liquidation
     *      until the buffer or the cap catches it. The sub-domain is non-vacuous, witnessed by hand: stRaw 100,
     *      jtRaw 0, jtEff 10, stEff 90, userStAssets 45 (neutral cap 5), userNAV 1, rate 2e18 gives desired 2,
     *      which binds below the buffer 10 and the cap 5 and pays double the redeemed NAV. Adjudication is to
     *      either cap the setter at WAD or accept and document the super-unitary rate as intended
     */
    function check_FINDING_candidate_bonusRateAboveOneHundredPercentPaysOutMoreThanTheRedeemedNAV(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 jtEff,
        uint256 covUtilWAD,
        uint256 liqThreshWAD,
        uint64 rate,
        uint256 userStAssets,
        uint256 userNAV
    )
        external
    {
        vm.assume(stRaw <= MAX_NAV && jtRaw <= MAX_NAV && jtEff <= MAX_NAV);
        vm.assume(userStAssets <= MAX_NAV && 1 <= userNAV && userNAV <= MAX_NAV);
        vm.assume(1 <= jtEff && jtEff <= stRaw + jtRaw);
        uint256 stEff = stRaw + jtRaw - jtEff;
        vm.assume(liqThreshWAD > WAD && covUtilWAD >= liqThreshWAD);
        vm.assume(stRaw > jtEff);
        vm.assume(1 <= userStAssets);
        // The divergent config region the setter accepts: a rate of at least 200%
        vm.assume(uint256(rate) >= 2 * WAD);

        // The desired slice at a super-unitary rate, plain checked arithmetic: at least double the redeemed NAV
        uint256 desired = (userNAV * uint256(rate)) / WAD;
        // Pin the sub-domain where the rate slice is the binding cap, through the senior-sourced case
        uint256 seniorSourcedCap = (userStAssets * jtEff) / (stRaw - jtEff);
        vm.assume(seniorSourcedCap <= _jtClaimOnSTRawNAV(jtRaw, jtEff));
        vm.assume(desired <= jtEff && desired <= seniorSourcedCap);

        sll.setSelfLiquidationBonusWAD(rate);
        (AssetClaims memory out, NAV_UNIT bonus) =
            sll.applyBonus(_syncedState(stRaw, jtRaw, stEff, jtEff, false, covUtilWAD, liqThreshWAD), _userClaims(userStAssets, 0, userNAV));

        // The paid bonus is the full super-unitary slice: strictly more than the NAV being redeemed
        assert(toUint256(bonus) == desired);
        assert(toUint256(bonus) > userNAV);
        assert(toUint256(out.nav) == userNAV + desired);
    }
}
