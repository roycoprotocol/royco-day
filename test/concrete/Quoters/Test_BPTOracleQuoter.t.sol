// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { stdError } from "../../../lib/forge-std/src/StdError.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";

/**
 * @title Test_OracleGuardAndConversions_BPTOracleQuoter
 * @notice The LT quoter's runtime surface: the setBPTOracle pool-attestation guard, the reinvestment slippage
 *         bound setter, BPT<->NAV conversion exactness against a pinned oracle TVL, the resolved quote asset,
 *         and the senior-share rate provider's unseeded floor
 * @dev setUp only deploys (18-dec vault share against a 6-dec quote, default params); each test seeds the exact
 *      state it derives its expected values from, so every assertion is exact or a documented floor identity
 */
contract Test_OracleGuardAndConversions_BPTOracleQuoter is DayMarketTestBase {
    function setUp() public virtual {
        _deployMarket(cellA(), defaultParams());
    }

    // =============================
    // setBPTOracle pool-attestation guard
    // =============================

    /// @notice An oracle pricing a DIFFERENT pool is rejected: the guard requires LPOracleBase(oracle).pool() to equal this market's LT asset
    function test_RevertIf_BPTOraclePricesForeignPool() public {
        MockBPTOracle foreignOracle = new MockBPTOracle(balancerVault, makeAddr("FOREIGN_POOL"));

        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(BalancerV3_LT_BPTOracle_Quoter.BPT_ORACLE_POOL_MISMATCH.selector);
        kernel.setBPTOracle(address(foreignOracle), false);
    }

    /**
     * @notice A right-pool oracle lands in storage with its event, and on BOTH sync-flag paths the trailing sync
     *         re-commits the LT raw NAV against the INCOMING oracle's mark
     * @dev Both paths end with a sync against the incoming oracle; the flag only controls whether the outgoing
     *      oracle gets a final sync first. Expected committed marks are hand-pinned MANUAL-mode TVLs
     */
    function test_SetBPTOracle_RecommitsLTRawNAVAgainstIncomingOracle_OnBothSyncFlagPaths() public {
        _seedMarket(100e18, 50e18); // JT then ST (auto-seeds minimal quote-only LT depth for the liquidity requirement)

        uint256 ownedBpt = toUint256(kernel.getState().ltOwnedYieldBearingAssets);
        uint256 bptSupply = balancerVault.totalSupply(address(bpt));

        // Path 1 (sync against the outgoing oracle first): a replacement pinned to a 3e18 TVL
        MockBPTOracle replacement = new MockBPTOracle(balancerVault, address(bpt));
        replacement.setTVL(3e18);
        replacement.setMode(MockBPTOracle.Mode.MANUAL);
        // Expected committed LT raw NAV under the incoming oracle: floor(TVL x ownedBPT / bptSupply)
        uint256 expectedLtRawNAV = Math.mulDiv(3e18, ownedBpt, bptSupply, Math.Rounding.Floor);

        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectEmit(true, false, false, true, address(kernel));
        emit BalancerV3_LT_BPTOracle_Quoter.BPTOracleUpdated(address(replacement));
        kernel.setBPTOracle(address(replacement), true);

        assertEq(kernel.getBalancerV3QuoterState().bptOracle, address(replacement), "the replacement oracle must land in quoter storage");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), expectedLtRawNAV, "the committed LT raw NAV must be re-marked against the incoming oracle");

        // Path 2 (no pre-sync against the outgoing oracle): a second replacement pinned to a 5e18 TVL
        MockBPTOracle secondReplacement = new MockBPTOracle(balancerVault, address(bpt));
        secondReplacement.setTVL(5e18);
        secondReplacement.setMode(MockBPTOracle.Mode.MANUAL);
        uint256 expectedSecondLtRawNAV = Math.mulDiv(5e18, ownedBpt, bptSupply, Math.Rounding.Floor);

        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectEmit(true, false, false, true, address(kernel));
        emit BalancerV3_LT_BPTOracle_Quoter.BPTOracleUpdated(address(secondReplacement));
        kernel.setBPTOracle(address(secondReplacement), false);

        assertEq(kernel.getBalancerV3QuoterState().bptOracle, address(secondReplacement), "the no-pre-sync path must also land the oracle in storage");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), expectedSecondLtRawNAV, "the no-pre-sync path must also re-commit against the incoming oracle");
    }

    /**
     * @notice The zero address has no pool() to attest: the guard's staticcall decodes empty returndata and reverts
     * @dev Justified bare expectRevert: an empty-returndata abi.decode failure carries no error selector
     */
    function test_RevertIf_BPTOracleSetToZeroAddress() public {
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert();
        kernel.setBPTOracle(address(0), false);
    }

    // =============================
    // Reinvestment slippage bound
    // =============================

    /// @notice The reinvestment slippage bound can be retuned below 100 percent, and the change lands with its event
    function test_SetMaxReinvestmentSlippage_UpdatesStateAndEmits() public {
        uint64 newSlippageWAD = 0.005e18;
        vm.expectEmit(address(kernel));
        emit BalancerV3_LT_BPTOracle_Quoter.MaxReinvestmentSlippageUpdated(newSlippageWAD);
        vm.prank(ORACLE_QUOTER_ADMIN);
        kernel.setMaxReinvestmentSlippage(newSlippageWAD);
        assertEq(kernel.getBalancerV3QuoterState().maxReinvestmentSlippageWAD, newSlippageWAD, "the slippage bound must land in quoter storage");
    }

    /// @notice A 100 percent slippage bound is rejected, it would let the single-sided add accept an arbitrarily bad fill
    function test_RevertIf_MaxReinvestmentSlippageIsFullWAD() public {
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(BalancerV3_LT_BPTOracle_Quoter.INVALID_MAX_REINVESTMENT_SLIPPAGE.selector);
        kernel.setMaxReinvestmentSlippage(uint64(WAD));
    }

    /**
     * @notice An unprivileged attacker can neither swap the BPT oracle nor loosen the reinvestment slippage bound,
     *         and the failed attempts leave the quoter state untouched
     * @dev Either setter is a full price-integrity takeover: a hostile oracle mismarks ltRawNAV at will, and a
     *      loosened slippage bound lets a sandwiched reinvestment donate the whole premium to the attacker
     */
    function test_RevertIf_LTQuoterSettersCalledByNonAdmin() public {
        address attacker = makeAddr("ATTACKER");
        MockBPTOracle hostileOracle = new MockBPTOracle(balancerVault, address(bpt));
        address oracleBefore = kernel.getBalancerV3QuoterState().bptOracle;
        uint64 slippageBefore = kernel.getBalancerV3QuoterState().maxReinvestmentSlippageWAD;

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        kernel.setBPTOracle(address(hostileOracle), false);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        kernel.setMaxReinvestmentSlippage(uint64(WAD) - 1);
        vm.stopPrank();

        assertEq(kernel.getBalancerV3QuoterState().bptOracle, oracleBefore, "the BPT oracle must be untouched by the failed attempts");
        assertEq(kernel.getBalancerV3QuoterState().maxReinvestmentSlippageWAD, slippageBefore, "the slippage bound must be untouched by the failed attempts");
    }

    // =============================
    // ltRawNAV conversion exactness
    // =============================

    /**
     * @notice BPT -> NAV is floor(TVL x bptAmount / bptSupply), pinned against a MANUAL-mode oracle TVL with the
     *         expected value recomputed independently, plus the floor-direction identity value x supply <= TVL x amount
     */
    function test_LTConvertTrancheUnitsToNAVUnits_ExactFloorAgainstPinnedTVL() public {
        bptOracle.setTVL(7e18);
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);

        uint256 bptSupply = balancerVault.totalSupply(address(bpt));
        assertGt(bptSupply, 0, "arrange: genesis minimum supply must exist");

        // A conversion amount chosen to force a non-exact division (7e18 x 3 not divisible by the genesis supply)
        uint256 amount = (bptSupply / 3) + 1;
        uint256 expected = Math.mulDiv(7e18, amount, bptSupply, Math.Rounding.Floor);

        uint256 got = toUint256(kernel.ltConvertTrancheUnitsToNAVUnits(toTrancheUnits(amount)));
        assertEq(got, expected, "the conversion must be floor(TVL x amount / supply)");
        // Floor direction: the conversion never overstates the LT's NAV
        assertLe(got * bptSupply, 7e18 * amount, "the floor bias must never overstate NAV");
    }

    /// @notice NAV -> BPT is the inverse floor: floor(supply x value / TVL)
    function test_LTConvertNAVUnitsToTrancheUnits_ExactFloorAgainstPinnedTVL() public {
        bptOracle.setTVL(7e18);
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);

        uint256 bptSupply = balancerVault.totalSupply(address(bpt));
        uint256 value = 1e18 + 3; // deliberately non-divisible
        uint256 expected = Math.mulDiv(bptSupply, value, 7e18, Math.Rounding.Floor);

        assertEq(toUint256(kernel.ltConvertNAVUnitsToTrancheUnits(toNAVUnits(value))), expected, "the conversion must be floor(supply x value / TVL)");
    }

    /**
     * @notice At TVL == 0 with BPT supply outstanding, BPT -> NAV marks exactly 0 without reverting (TVL is the numerator
     *         of the mark), while NAV -> BPT panics with division-by-zero (TVL is the denominator of the inverse)
     * @dev This directional asymmetry is why the raw-NAV mark itself never bricks a sync: the sync only ever reads the
     *      tolerant BPT -> NAV direction, and the sole sync-bricking consumer of the panicking inverse is the reinvest
     *      path's NAV -> tranche division (pinned in the sibling reinvest test file). This test pins the exact boundary
     *      between the tolerant and the panicking direction
     */
    function test_LTConvertTrancheUnitsToNAVUnits_ZeroTVLWithSupply_MarksZeroWithoutRevert() public {
        bptOracle.setTVL(0);
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);

        // Supply must be nonzero so neither direction takes its zero-supply early return: only the TVL is zero here
        uint256 bptSupply = balancerVault.totalSupply(address(bpt));
        assertGt(bptSupply, 0, "arrange: genesis minimum supply must exist so the zero-supply early return is not taken");

        // BPT -> NAV: floor(TVL x amount / supply) = floor(0 x 1e18 / supply) = 0 for ANY positive supply, so a
        // worthless pool marks at exactly zero and never divides by zero
        assertEq(toUint256(kernel.ltConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 0, "a zero TVL must mark the BPT at exactly zero NAV, not revert");

        // NAV -> BPT: floor(supply x value / TVL) divides by TVL == 0, so the inverse direction panics (0x12)
        vm.expectRevert(stdError.divisionError);
        kernel.ltConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(1e18)));
    }

    /// @notice A reverting oracle bricks the LT mark: the conversion path surfaces the oracle failure rather than guessing
    function test_RevertIf_BPTOracleRevertsDuringConversion() public {
        bptOracle.setRevertMode(true);
        vm.expectRevert(MockBPTOracle.ORACLE_REVERT_MODE.selector);
        kernel.ltConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18));
    }

    // =============================
    // Constructor-resolved state and the rate provider floor
    // =============================

    /// @notice QUOTE_ASSET resolves from the registered pool token order to the token that is not the senior tranche share
    function test_Construction_ResolvesQuoteAssetFromRegistration() public view {
        assertEq(kernel.QUOTE_ASSET(), address(quoteToken), "the quote asset must resolve from the pool registration");
    }

    /**
     * @notice Before the senior tranche is seeded the rate floors to exactly 1 wei, never zero
     * @dev With zero supply the effective NAV per share is 0, and the pool would reject a zero rate, so the
     *      provider floors it at 1 wei. This is inert: an unseeded market has an empty senior pool leg to scale
     */
    function test_GetRate_UnseededMarketFloorsAtOneWei() public view {
        assertEq(kernel.getRate(), 1, "the rate on an unseeded market must be the 1-wei floor");
    }
}

/**
 * @title Test_SeniorShareRateProvider_BPTOracleQuoter
 * @notice The seeded senior-share rate provider on a zero-fee/zero-premium market, hand-exact by construction
 * @dev Seeding happens in setUp DELIBERATELY: Foundry clears transient storage between setUp and the test body, so
 *      each test starts with an unset senior share rate cache, mirroring production where every user interaction is
 *      its own transaction. (Seeding inside a test body leaves the seeding syncs' cache visible to the assertions)
 */
contract Test_SeniorShareRateProvider_BPTOracleQuoter is DayMarketTestBase {
    function setUp() public virtual {
        MarketParamsConfig memory p = defaultParams();
        p.stProtocolFeeWAD = 0;
        p.jtProtocolFeeWAD = 0;
        p.jtYieldShareProtocolFeeWAD = 0;
        p.ltYieldShareProtocolFeeWAD = 0;
        p.maxJTYieldShareWAD = 0;
        p.maxLTYieldShareWAD = 0;
        p.jtCurve = [uint64(0), uint64(0), uint64(0)];
        p.ltCurve = [uint64(0), uint64(0), uint64(0)];
        _deployMarket(cellA(), p);
        _seedMarket(100e18, 50e18);
    }

    /**
     * @notice The live rate path is exact and the post-sync cached rate equals it, hand-derived on the
     *         zero-fee/zero-premium market
     * @dev Seeded 100e18 ST at rate 1.0 gives stEff = 100e18 over supply 100e18 = 1.0. A +10% vault accrual moves
     *      stEff to 110e18 with the supply unchanged (no fee and liquidity premium share mint at zero config), so
     *      the live rate is floor(110e18 x 1e18 / 100e18) = 1.1e18, and the post-sync cache must equal it
     */
    function test_GetRate_LivePathExact_AndCacheParityAfterSync() public {
        applySTPnL(1000); // +10.00%
        uint256 liveRate = kernel.getRate(); // cache unset at test entry: live preview path
        assertEq(liveRate, 1.1e18, "the live rate must be the hand-derived 1.1e18");

        vm.prank(SYNC_OPERATOR);
        kernel.syncTrancheAccounting(); // writes the transient senior share rate cache
        assertEq(kernel.getRate(), liveRate, "the cached rate must equal the live rate (same block, same state)");
    }

    /**
     * @notice Once a sync has cached the rate, an inline senior-share mint (supply +100%) cannot move the rate the
     *         venue sees within the same transaction
     * @dev Attacker intent: sandwich a sync with a supply move so the pool prices its senior leg off a rate the
     *      attacker just shifted. The transaction-scoped cache pins the rate for the rest of the transaction
     */
    function test_GetRate_TransactionInvariant_UnderInlineSeniorMint() public {
        vm.prank(SYNC_OPERATOR);
        kernel.syncTrancheAccounting();
        uint256 cachedRate = kernel.getRate();
        assertEq(cachedRate, 1e18, "arrange: the cached rate at seed must be exactly 1.0");

        // Inline senior mint: doubles the supply mid-transaction (through the tranche's kernel-only mint gate)
        vm.prank(address(kernel));
        seniorTranche.mint(makeAddr("INLINE_MINT_RECIPIENT"), 100e18);

        assertEq(kernel.getRate(), cachedRate, "the rate must be unchanged by an inline supply move, the cache pins it");
    }
}
