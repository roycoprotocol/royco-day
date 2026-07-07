// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Math } from "../../src/libraries/Units.sol";
import { CarveOutWrapper } from "../mocks/CarveOutWrapper.sol";
import { LTEffectiveNAVDriver } from "../mocks/LTEffectiveNAVDriver.sol";

/**
 * @title CarveOutSharesSymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the post-sync senior-share carve-out sizing:
 *         the joint pricing of the LT liquidity premium and the ST protocol fee against the pre-sync senior
 *         supply, and the share-conversion primitive both carve-outs (and the JT/LT protocol fee mints) are
 *         priced with. The load-bearing properties: the sizing is total whenever the waterfall's contract
 *         (premium plus fee fit inside senior effective NAV) holds, pre-existing senior holders are never
 *         diluted below their retained NAV, each carve-out receives its NAV to within one post-mint share of
 *         value on either side, zero carve-outs mint nothing, an empty supply prices one-to-one, a fully
 *         carved-out NAV prices against the one-wei fallback denominator in both clamp regions, and fee
 *         shares minted against a post-fee NAV are worth at most the fee they collect
 * @dev Run with `forge test --symbolic --match-path test/symbolic/CarveOutSharesSymbolic.t.sol`. Functions
 *      prefixed check_ are discovered only under --symbolic. Domain: NAV legs up to 1e30 NAV wei (one
 *      trillion whole 18-decimal tokens, beyond any underwritable market), share supplies up to 2^96 (2^128
 *      for the extended totality check). Every expected value is derived independently: plain checked
 *      multiply-and-divide where the product provably fits uint256, or two-sided product brackets stated on
 *      the production outputs, never by re-running the production mulDiv chain as its own expectation
 * @dev Two checks are DIVERGENCE candidates: they pin that the LT protocol fee can exceed the LT effective NAV
 *      when the premium share mint is starved (or floor-shorted) at a 100% LT yield share fee, which makes
 *      the checked subtraction that prices the LT fee shares against the fee-net LT effective NAV underflow
 *      and brick the whole sync
 */
contract CarveOutSharesSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /// @dev The mint-dilution residual: any single mint leaves pre-existing holders at least EPS/WAD of the
    ///      post-mint supply. EPS divides WAD, so the clamp cap is exactly supply * (WAD/EPS - 1) with no floor loss
    uint256 internal constant EPS = 1e6;

    /// @dev The exact per-supply-unit clamp cap multiplier: (WAD - EPS) / EPS == 1e12 - 1, an integer because EPS divides WAD
    uint256 internal constant CLAMP_CAP_PER_SUPPLY_UNIT = (WAD - EPS) / EPS;

    CarveOutWrapper internal wrapper;
    LTEffectiveNAVDriver internal ltDriver;

    function setUp() public {
        wrapper = new CarveOutWrapper();
        ltDriver = new LTEffectiveNAVDriver();
    }

    /*//////////////////////////////////////////////////////////////////////
                TOTALITY UNDER THE WATERFALL'S CONTAINMENT CONTRACT
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The carve-out sizing never reverts as long as the liquidity premium and the ST protocol fee
     *         together fit inside the senior effective NAV, which is exactly what the waterfall guarantees:
     *         it books both carve-outs into senior effective NAV before reporting them, so the retained-NAV
     *         subtraction can never underflow and no share conversion downstream of it can revert
     * @dev Why totality matters: this sizing runs inside every premium-paying sync, so a revert here would
     *      brick deposits, redemptions, and premium payments all at once. The containment precondition is the
     *      waterfall's own output contract (proven separately as the fee-plus-premium-within-senior-NAV sync
     *      lemma) and is consumed here as a vm.assume domain fact. Inside it, the retained subtraction is a
     *      checked sub of two contained legs, the clamp bind test is the overflow-free full-precision form,
     *      the clamp branch product supply * (WAD - EPS) / EPS fits uint256 for supplies up to 2^128, and the
     *      fair branch quotient is bounded by the clamp cap, so no arithmetic step can overflow. The supply
     *      bound 2^128 is the extended-totality domain, far beyond the 1e30-wei suite bound the other checks
     *      use. The padding input routes the query past the engine's built-in arithmetic heuristic to the
     *      real SMT solver
     */
    function check_carveOutShareSizingNeverRevertsWhenPremiumAndFeeFitInSeniorNAV(
        uint256 stEff,
        uint256 premium,
        uint256 fee,
        uint256 supply,
        uint256 p1
    )
        external
        view
    {
        // The waterfall's containment contract: both carve-outs are booked inside senior effective NAV
        vm.assume(premium <= stEff && fee <= stEff - premium);
        vm.assume(supply <= 2 ** 128);
        vm.assume(p1 <= 3);

        try wrapper.computeSTFeeAndLiquidityPremiumSharesToMint(stEff, premium, fee, supply + p1 - p1) returns (uint256, uint256, uint256) {
            // Total on the whole contract domain: every premium-paying sync can always size its mints
        } catch {
            assert(false);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                PRE-EXISTING HOLDERS ARE NEVER DILUTED BELOW RETAINED NAV
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On the fair-priced branch, the pre-existing senior shares are always worth at least the
     *         retained senior NAV after both carve-out mints settle: pricing the premium and the fee jointly
     *         against the same retained-NAV denominator means neither mint dilutes the pre-existing holders
     *         below the NAV the waterfall left them, and neither carve-out dilutes the other
     * @dev Derivation, on outputs only: each floored share count satisfies shares * retained <= value * supply,
     *      so summing both legs gives (premiumShares + feeShares) * retained <= (premium + fee) * supply.
     *      Adding retained * supply to both sides yields retained * supplyAfter <= stEff * supply, which read
     *      per share says the post-mint price stEff / supplyAfter values the original supply at no less than
     *      the retained NAV. Flooring both mints can only strengthen the bound (the carve-outs eat the
     *      rounding dust, never the holders). Stated as one degree-2 product comparison with no division on
     *      the spec side. The padding input routes the query past the engine's built-in arithmetic heuristic
     *      to the real SMT solver
     */
    function check_preExistingSeniorSharesRetainAtLeastRetainedNAV(
        uint256 retained,
        uint256 premium,
        uint256 fee,
        uint256 supply,
        uint256 p1
    )
        external
        view
    {
        // A live market on the fair-priced branch: positive retained NAV and supply, both legs below the clamp
        vm.assume(1 <= retained && retained <= MAX_NAV);
        vm.assume(1 <= supply && supply <= 2 ** 96);
        vm.assume(premium <= MAX_NAV && fee <= MAX_NAV);
        vm.assume(premium * EPS <= retained * (WAD - EPS));
        vm.assume(fee * EPS <= retained * (WAD - EPS));
        vm.assume(p1 <= 3);
        // The senior effective NAV is the retained NAV plus everything carved out of it
        uint256 stEff = retained + premium + fee;

        (,, uint256 supplyAfter) = wrapper.computeSTFeeAndLiquidityPremiumSharesToMint(stEff, premium, fee, supply + p1 - p1);

        // The original supply, valued at the post-mint price, still covers the whole retained NAV:
        // stEff / supplyAfter >= retained / supply, cross-multiplied to stay division-free
        assert(stEff * supply >= retained * supplyAfter);
    }

    /*//////////////////////////////////////////////////////////////////////
                EACH CARVE-OUT RECEIVES ITS NAV WITHIN ONE POST-MINT SHARE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On the fair-priced branch the liquidity premium mint is value-exact to within share-count
     *         granularity: the minted premium shares, valued at the post-mint price, fall short of the
     *         premium by less than one post-mint share's value and overshoot it by at most two
     * @dev Why two-sided: the shortfall side is the LT's protection (the premium the waterfall reported
     *      cannot silently evaporate into rounding beyond one share of dust) and the overshoot side is the
     *      pre-existing holders' protection (the mint cannot extract measurably more than the premium).
     *      Derivation from the exact joint-pricing algebra: with retained = stEff - premium - fee the real
     *      solution mints shares worth exactly the premium, so the only drift is the two floors. The floor
     *      brackets premiumShares * retained <= premium * supply < (premiumShares + 1) * retained (and the
     *      same for the fee leg) rearrange to the two product inequalities asserted below, each degree-2 with
     *      no spec-side division. The padding input routes the query past the engine's built-in arithmetic
     *      heuristic to the real SMT solver
     */
    function check_liquidityPremiumLegReceivesItsNAVWithinOnePostMintShare(
        uint256 retained,
        uint256 premium,
        uint256 fee,
        uint256 supply,
        uint256 p1
    )
        external
        view
    {
        // A live market on the fair-priced branch for both carve-out legs
        vm.assume(1 <= retained && retained <= MAX_NAV);
        vm.assume(1 <= supply && supply <= 2 ** 96);
        vm.assume(premium <= MAX_NAV && fee <= MAX_NAV);
        vm.assume(premium * EPS <= retained * (WAD - EPS));
        vm.assume(fee * EPS <= retained * (WAD - EPS));
        vm.assume(p1 <= 3);
        uint256 stEff = retained + premium + fee;

        (uint256 premiumShares,, uint256 supplyAfter) = wrapper.computeSTFeeAndLiquidityPremiumSharesToMint(stEff, premium, fee, supply + p1 - p1);

        // Shortfall side: premium - value(premiumShares) < one post-mint share's value, cross-multiplied by
        // supplyAfter into premium * supplyAfter <= stEff * premiumShares + stEff
        assert(premium * supplyAfter <= stEff * premiumShares + stEff);
        // Overshoot side: value(premiumShares) <= premium plus two post-mint shares' value, cross-multiplied
        // into stEff * premiumShares <= premium * (supplyAfter + 2)
        assert(stEff * premiumShares <= premium * (supplyAfter + 2));
    }

    /**
     * @notice On the fair-priced branch the ST protocol fee mint is value-exact to within share-count
     *         granularity: the minted fee shares, valued at the post-mint price, fall short of the fee by
     *         less than one post-mint share's value and overshoot it by at most two
     * @dev The mirror of the premium-leg check: the shortfall side protects the protocol (the configured fee
     *      cannot round away beyond one share of dust) and the overshoot side protects senior holders (the
     *      fee mint cannot collect measurably more than the waterfall reported). Same floor-bracket
     *      derivation with the two legs' roles swapped, degree-2 products, no spec-side division. The padding
     *      input routes the query past the engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_protocolFeeLegReceivesItsNAVWithinOnePostMintShare(
        uint256 retained,
        uint256 premium,
        uint256 fee,
        uint256 supply,
        uint256 p1
    )
        external
        view
    {
        // A live market on the fair-priced branch for both carve-out legs
        vm.assume(1 <= retained && retained <= MAX_NAV);
        vm.assume(1 <= supply && supply <= 2 ** 96);
        vm.assume(premium <= MAX_NAV && fee <= MAX_NAV);
        vm.assume(premium * EPS <= retained * (WAD - EPS));
        vm.assume(fee * EPS <= retained * (WAD - EPS));
        vm.assume(p1 <= 3);
        uint256 stEff = retained + premium + fee;

        (, uint256 feeShares, uint256 supplyAfter) = wrapper.computeSTFeeAndLiquidityPremiumSharesToMint(stEff, premium, fee, supply + p1 - p1);

        // Shortfall side: the fee shares are short of the fee by less than one post-mint share's value
        assert(fee * supplyAfter <= stEff * feeShares + stEff);
        // Overshoot side: the fee shares are worth at most the fee plus two post-mint shares' value
        assert(stEff * feeShares <= fee * (supplyAfter + 2));
    }

    /*//////////////////////////////////////////////////////////////////////
                        ZERO CARVE-OUTS MINT NOTHING
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A sync that reports no liquidity premium sizes exactly zero premium shares, whatever the fee
     *         leg and the retained NAV look like: no sync can reassign senior share ownership to the LT
     *         without the waterfall having actually carved a premium out of senior yield
     */
    function check_zeroPremiumMintsNoPremiumShares(uint256 stEff, uint256 fee, uint256 supply, uint256 p1, uint256 p2) external view {
        vm.assume(stEff <= MAX_NAV && fee <= stEff);
        vm.assume(1 <= supply && supply <= 2 ** 96);
        vm.assume(p1 <= 3 && p2 <= 3);

        // A zero value can neither trip the clamp bind test nor floor to a positive share count, so the
        // downstream mint guard stays silent and no senior shares move toward the liquidity tranche
        (uint256 premiumShares,,) = wrapper.computeSTFeeAndLiquidityPremiumSharesToMint(stEff + p1 - p1, 0, fee, supply + p2 - p2);
        assert(premiumShares == 0);
    }

    /**
     * @notice A sync that reports no ST protocol fee sizes exactly zero fee shares, whatever the premium leg
     *         and the retained NAV look like: the protocol cannot collect senior shares on a sync where the
     *         waterfall reported no senior fee
     */
    function check_zeroFeeMintsNoFeeShares(uint256 stEff, uint256 premium, uint256 supply, uint256 p1, uint256 p2) external view {
        vm.assume(stEff <= MAX_NAV && premium <= stEff);
        vm.assume(1 <= supply && supply <= 2 ** 96);
        vm.assume(p1 <= 3 && p2 <= 3);

        // Same zero-value argument as the premium leg: no bind, a zero floor, and a silent mint guard
        (, uint256 feeShares,) = wrapper.computeSTFeeAndLiquidityPremiumSharesToMint(stEff + p1 - p1, premium, 0, supply + p2 - p2);
        assert(feeShares == 0);
    }

    /**
     * @notice A sync that reports neither carve-out leaves the senior share supply exactly untouched: the
     *         carve-out sizing is a strict no-op on every sync that pays no premium and takes no senior fee,
     *         so plain ST/JT syncs cannot leak even a wei of dilution through this path
     */
    function check_zeroCarveOutsLeaveSeniorSupplyUntouched(uint256 stEff, uint256 supply, uint256 p1, uint256 p2) external view {
        vm.assume(stEff <= MAX_NAV);
        vm.assume(1 <= supply && supply <= 2 ** 96);
        vm.assume(p1 <= 3 && p2 <= 3);

        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) =
            wrapper.computeSTFeeAndLiquidityPremiumSharesToMint(stEff + p1 - p1, 0, 0, supply + p2 - p2);

        // Both legs floor to zero and the post-mint supply is byte-identical to the pre-sync supply
        assert(premiumShares == 0);
        assert(feeShares == 0);
        assert(supplyAfter == supply);
    }

    /*//////////////////////////////////////////////////////////////////////
                    BOOTSTRAP SUPPLY PRICES ONE-TO-ONE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice With no senior shares outstanding, both carve-outs price one NAV wei to one share: the premium
     *         mints exactly its NAV, the fee mints exactly its NAV, and the post-mint supply is their sum
     * @dev Why one-to-one: with zero supply there is nobody to dilute, so the conversion mirrors a tranche's
     *      first deposit (the same rule the tranche vaults use), and the mint-dilution clamp is exempt
     *      because pre-existing holders with zero shares retain nothing by definition. This is the boundary
     *      a brand-new market's very first premium-paying sync crosses, so mis-pricing here would seed the
     *      senior share price wrong for every subsequent mint
     */
    function check_bootstrapSupplyPricesCarveOutsOneToOne(uint256 stEff, uint256 premium, uint256 fee, uint256 p1, uint256 p2) external view {
        vm.assume(stEff <= MAX_NAV);
        vm.assume(premium <= stEff && fee <= stEff - premium);
        vm.assume(p1 <= 3 && p2 <= 3);

        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) =
            wrapper.computeSTFeeAndLiquidityPremiumSharesToMint(stEff + p1 - p1, premium, fee + p2 - p2, 0);

        // One share per NAV wei on both legs, and the supply after the mints is exactly their sum
        assert(premiumShares == premium);
        assert(feeShares == fee);
        assert(supplyAfter == premium + fee);
    }

    /*//////////////////////////////////////////////////////////////////////
            A FULL CARVE-OUT PRICES AGAINST THE ONE-WEI DENOMINATOR
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice When the carve-outs consume the entire senior effective NAV (the retained NAV is zero) and each
     *         leg is small enough to stay below the mint-dilution clamp, the conversion prices against the
     *         one-wei fallback denominator: each leg mints exactly its NAV times the whole pre-sync supply
     * @dev Why the fallback denominator: a zero retained NAV means the pre-existing shares are momentarily
     *      unbacked, and pricing against a literal zero would divide by zero. Valuing the existing supply at
     *      one NAV wei total instead deliberately dilutes the unbacked holders toward the incoming value,
     *      which is the same rule the tranche vaults apply to deposits into a zero-NAV vault. Below the
     *      clamp the fair floor over a denominator of one collapses to a plain product, value * supply, with
     *      no rounding at all. The clamp region of this same call site is pinned by the following check
     */
    function check_fullCarveOutBelowDilutionClampPricesAtOneWeiDenominator(uint256 premium, uint256 fee, uint256 supply, uint256 p1, uint256 p2) external view {
        // Both legs stay strictly below the bind boundary against a one-wei denominator: the bind test
        // value * EPS > 1 * (WAD - EPS) first trips at value == WAD/EPS == 1e12, so cap each leg one below
        vm.assume(1 <= premium && premium <= CLAMP_CAP_PER_SUPPLY_UNIT);
        vm.assume(fee <= CLAMP_CAP_PER_SUPPLY_UNIT);
        vm.assume(1 <= supply && supply <= 2 ** 96);
        vm.assume(p1 <= 3 && p2 <= 3);
        // The whole senior effective NAV is carved out, leaving the pre-existing shares zero retained NAV
        uint256 stEff = premium + fee;

        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) =
            wrapper.computeSTFeeAndLiquidityPremiumSharesToMint(stEff + p1 - p1, premium, fee, supply + p2 - p2);

        // Each leg's floor over the one-wei denominator is the exact product value * supply
        assert(premiumShares == premium * supply);
        assert(feeShares == fee * supply);
        assert(supplyAfter == supply + premium * supply + fee * supply);
    }

    /**
     * @notice When the carve-out consumes the entire senior effective NAV and is large enough to trip the
     *         mint-dilution clamp against the one-wei fallback denominator, the mint is capped at exactly
     *         supply * (WAD/EPS - 1) shares: the pre-existing holders, however unbacked, always retain at
     *         least the dilution residual of the post-mint supply
     * @dev Why the cap must bind here: with a one-wei denominator the fair price would hand the carve-out
     *      value * supply shares, which for any real premium is an astronomically dominant stake minted in a
     *      single sync. The clamp bounds any single mint's ownership of the post-mint supply instead, and
     *      because EPS divides WAD the cap floor(supply * (WAD - EPS) / EPS) is the exact product
     *      supply * (WAD/EPS - 1) with no rounding loss, so the expected form is a plain multiply
     */
    function check_fullCarveOutAtDilutionClampCapsAtPreMintSupplyResidual(uint256 premium, uint256 supply, uint256 p1, uint256 p2, uint256 p3) external view {
        // The premium leg trips the bind test against the one-wei denominator: premium * EPS > WAD - EPS,
        // which for integers is exactly premium >= WAD/EPS == 1e12. The fee leg is pinned to zero so this
        // check pins the clamp region alone
        vm.assume(CLAMP_CAP_PER_SUPPLY_UNIT < premium && premium <= MAX_NAV);
        vm.assume(1 <= supply && supply <= 2 ** 96);
        vm.assume(p1 <= 3 && p2 <= 3 && p3 <= 3);

        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) =
            wrapper.computeSTFeeAndLiquidityPremiumSharesToMint(premium + p1 - p1, premium + p2 - p2, 0, supply + p3 - p3);

        // The clamped mint leaves the pre-existing supply exactly the dilution residual of the post-mint supply
        assert(premiumShares == supply * CLAMP_CAP_PER_SUPPLY_UNIT);
        assert(feeShares == 0);
        assert(supplyAfter == supply + supply * CLAMP_CAP_PER_SUPPLY_UNIT);
    }

    /*//////////////////////////////////////////////////////////////////////
            FEE SHARES MINTED AGAINST POST-FEE NAV ARE WORTH THE FEE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The junior protocol fee mint prices the fee against the junior NAV net of the fee, so the
     *         minted shares dilute the existing junior holders by exactly the fee: valued at the post-mint
     *         price the fee shares are worth at most the fee, and at least the fee minus one whole-NAV unit
     *         of flooring dust
     * @dev Derivation: shares = floor(fee * supply / (nav - fee)) satisfies the floor bracket
     *      shares * (nav - fee) <= fee * supply < (shares + 1) * (nav - fee). Adding shares * fee to the
     *      left inequality gives shares * nav <= fee * (supply + shares), the at-most side. Expanding the
     *      right inequality gives shares * nav > fee * (supply + shares) - (nav - fee), which for integers
     *      is the at-least side stated addition-only to stay underflow-free. Why it matters: overshooting
     *      would tax junior holders beyond the configured percentage of their own yield, and undershooting
     *      by more than dust would silently rebate the protocol's fee back to the tranche
     */
    function check_juniorFeeSharesMintedAgainstPostFeeNAVAreWorthAtMostTheFee(uint256 fee, uint256 nav, uint256 supply, uint256 p1, uint256 p2) external view {
        // A live junior tranche whose effective NAV strictly contains the accrued fee, on the fair branch
        vm.assume(1 <= fee && fee < nav && nav <= MAX_NAV);
        vm.assume(1 <= supply && supply <= 2 ** 96);
        vm.assume(fee * EPS <= (nav - fee) * (WAD - EPS));
        vm.assume(p1 <= 3 && p2 <= 3);

        uint256 feeShares = wrapper.convertToShares(fee + p1 - p1, nav - fee, supply + p2 - p2, Math.Rounding.Floor);

        // At most the fee: the recipient's post-mint slice never exceeds what the waterfall reported
        assert(nav * feeShares <= fee * (supply + feeShares));
        // At least the fee minus flooring dust: the protocol is shorted by less than one NAV of drift
        assert(nav * feeShares + nav >= fee * (supply + feeShares));
    }

    /**
     * @notice The liquidity tranche protocol fee mint prices the fee against the LT effective NAV net of the
     *         fee through the same primitive, so the minted LT shares are likewise worth at most the fee and
     *         at least the fee minus one whole-NAV unit of flooring dust at the post-mint price
     * @dev Identical floor-bracket derivation as the junior leg with the LT effective NAV (market-making
     *      depth plus idle premium) as the pricing NAV. Kept as its own check because the LT mint is a
     *      distinct production call site whose NAV leg is assembled differently, and whose fee-net
     *      subtraction has its own reachability question (pinned by the DIVERGENCE candidates below)
     */
    function check_liquidityFeeSharesMintedAgainstPostFeeNAVAreWorthAtMostTheFee(uint256 fee, uint256 nav, uint256 supply, uint256 p1, uint256 p2) external view {
        // A live liquidity tranche whose effective NAV strictly contains the accrued fee, on the fair branch
        vm.assume(1 <= fee && fee < nav && nav <= MAX_NAV);
        vm.assume(1 <= supply && supply <= 2 ** 96);
        vm.assume(fee * EPS <= (nav - fee) * (WAD - EPS));
        vm.assume(p1 <= 3 && p2 <= 3);

        uint256 feeShares = wrapper.convertToShares(fee + p1 - p1, nav - fee, supply + p2 - p2, Math.Rounding.Floor);

        // The same two-sided dilution-pricing bracket as the junior leg, on the LT's own NAV
        assert(nav * feeShares <= fee * (supply + feeShares));
        assert(nav * feeShares + nav >= fee * (supply + feeShares));
    }

    /*//////////////////////////////////////////////////////////////////////
        DIVERGENCE CANDIDATES: THE LT FEE CAN EXCEED THE LT EFFECTIVE NAV
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice PINS A DIVERGENCE. When the liquidity premium is worth less than one senior share (the floored
     *         premium mint sizes zero shares), the liquidity tranche receives nothing at all, yet the
     *         waterfall still reports the full LT protocol fee on the premium it never delivered. At a 100%
     *         LT yield share fee against an LT with no market-making inventory, the fee then strictly exceeds
     *         the LT effective NAV, so the fee-net subtraction the LT fee mint prices against underflows and
     *         the entire sync reverts: deposits, redemptions, and premium payments are all bricked until the
     *         senior share price or the accrued premium moves the sizing off the starvation edge
     * @dev The starvation domain: the premium times the pre-sync supply is below the retained NAV, so the
     *      floored premium mint is exactly zero shares and the premium mint block (and with it the held
     *      senior share credit) is skipped entirely. The LT effective NAV, computed through the production
     *      valuation path with zero held senior shares and zero raw inventory, is then exactly zero, while
     *      the reported fee at a 100% yield share fee is floor(premium * WAD / WAD) == premium >= 1 wei.
     *      Witness: retained 2, premium 1, supply 1. Each draw is wei-scale, but the revert is a full sync
     *      DoS in whatever market state reaches it, not a value leak
     */
    function check_DIVERGENCE_candidate_starvedPremiumMintLeavesLtFeeAboveLtEffectiveNAV(uint256 retained, uint256 premium, uint256 supply, uint256 p1) external {
        // The premium is real but worth less than one senior share at the current price: its floored mint
        // sizes zero shares. The bind test cannot trip first because the bind threshold is above one share's
        // NAV: ceil(premium * EPS / (WAD - EPS)) <= premium <= premium * supply < retained
        vm.assume(1 <= premium && premium <= MAX_NAV);
        vm.assume(1 <= supply && supply <= 2 ** 96);
        vm.assume(premium * supply < retained && retained <= MAX_NAV);
        vm.assume(p1 <= 3);
        // No ST protocol fee this sync, so the senior effective NAV is the retained NAV plus the premium
        uint256 stEff = retained + premium;

        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) =
            wrapper.computeSTFeeAndLiquidityPremiumSharesToMint(stEff, premium, 0, supply + p1 - p1);

        // Starvation through the production sizing: the premium mint floors to zero shares
        assert(premiumShares == 0);
        assert(feeShares == 0);

        // The LT holds no idle senior shares (the mint was skipped) and no market-making inventory, so the
        // production LT effective NAV path early-returns its raw NAV: exactly zero
        ltDriver.setLTRawNAV(0);
        ltDriver.setLTOwnedSeniorTrancheShares(0);
        uint256 ltEffectiveNAV = ltDriver.ltEffectiveNAV(stEff, supplyAfter);
        assert(ltEffectiveNAV == 0);

        // At a 100% LT yield share fee the waterfall reports floor(premium * WAD / WAD) == premium as the LT
        // fee. The fee strictly exceeds the LT effective NAV, so pricing the fee shares against the fee-net
        // LT effective NAV is a checked subtraction that underflows and reverts the whole sync
        uint256 ltProtocolFee = premium;
        assert(ltProtocolFee > ltEffectiveNAV);
    }

    /**
     * @notice PINS A DIVERGENCE. Even when the premium mint sizes a positive share count, flooring shorts the
     *         minted shares' value below the reported premium whenever the division has a remainder. At a
     *         100% LT yield share fee against an LT with no market-making inventory, the LT's entire
     *         effective NAV is those floor-shorted idle shares, so the reported fee (the full premium)
     *         strictly exceeds the LT effective NAV and the fee-net subtraction the LT fee mint prices
     *         against underflows, reverting the whole sync
     * @dev The floor-shortfall domain: premiumShares * retained < premium * supply strictly (a nonzero
     *      division remainder), which rearranges to premiumShares * stEff < premium * supplyAfter, so the
     *      idle shares valued at the post-mint price floor strictly below the premium. Witness: retained 4,
     *      premium 3, supply 2 sizes one share worth floor(7/3) == 2 against a reported fee of 3. Unlike the
     *      starvation arm this needs no extreme share price, only a remainder, so it is the generic
     *      reachability of the underflow at any 100%-fee market whose LT has no deployed inventory yet
     */
    function check_DIVERGENCE_candidate_flooredPremiumValueLeavesLtFeeAboveLtEffectiveNAV(uint256 retained, uint256 premium, uint256 supply, uint256 p1) external {
        // A live fair-branch premium mint that sizes at least one share but with a division remainder
        vm.assume(1 <= retained && retained <= MAX_NAV);
        vm.assume(1 <= premium && premium <= MAX_NAV);
        vm.assume(1 <= supply && supply <= 2 ** 96);
        vm.assume(premium * EPS <= retained * (WAD - EPS));
        vm.assume(premium * supply >= retained);
        vm.assume((premium * supply) % retained != 0);
        vm.assume(p1 <= 3);
        // No ST protocol fee this sync, so the senior effective NAV is the retained NAV plus the premium
        uint256 stEff = retained + premium;

        (uint256 premiumShares,, uint256 supplyAfter) = wrapper.computeSTFeeAndLiquidityPremiumSharesToMint(stEff, premium, 0, supply + p1 - p1);
        assert(premiumShares >= 1);

        // The LT's whole effective NAV is the freshly minted idle senior shares, valued through the
        // production valuation path at the post-mint senior share price, with no market-making inventory
        ltDriver.setLTRawNAV(0);
        ltDriver.setLTOwnedSeniorTrancheShares(premiumShares);
        uint256 ltEffectiveNAV = ltDriver.ltEffectiveNAV(stEff, supplyAfter);

        // At a 100% LT yield share fee the reported fee is the full premium, which strictly exceeds the
        // floor-shorted value of the shares that actually landed: the fee-net subtraction underflows and
        // bricks the sync
        uint256 ltProtocolFee = premium;
        assert(ltProtocolFee > ltEffectiveNAV);
    }
}
