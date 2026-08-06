// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { IYDM } from "../../../src/interfaces/IYDM.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { MarketState, TrancheType } from "../../../src/libraries/Types.sol";
import { FixedYDM } from "../../../src/ydm/FixedYDM.sol";

/**
 * @title Test_FixedYDM
 * @notice Unit tests for the fixed (utilization-independent) yield share model. Stateful invariant
 *         coverage lives in test/invariant/Invariant_YDM.t.sol.
 * @dev Every expected value is hand-derived from src/ydm/FixedYDM.sol. No call to the contract
 *      under test ever appears on the expected side of an assertion.
 *
 * Model: Y(U) = fixedYieldShareWAD for every U and every market state, with an explicit initialized
 * flag so a configured zero share stays distinguishable from an uninitialized market (fail shut).
 */
contract Test_FixedYDM is Test {
    // Distinct non-test accountant address for per-sender keying tests.
    address constant ACCT_B = address(0xB0B);

    event FixedYdmInitialized(address indexed accountant, TrancheType indexed trancheType, uint256 fixedYieldShareWAD);
    event YdmOutput(address indexed accountant, TrancheType indexed trancheType, uint256 yieldShareWAD);

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    /// The reference share: init(3e17) => Y(U) == 3e17 everywhere.
    function _referenceShare() internal returns (FixedYDM ydm) {
        ydm = new FixedYDM();
        ydm.initializeYDMForMarket(TrancheType.JUNIOR, 3e17);
    }

    // =====================================================================
    // initializeYDMForMarket parameter validation
    // =====================================================================

    /// A share above WAD could pay more than the whole gain and is rejected
    function test_RevertIf_InitializeShareAboveWad() public {
        FixedYDM ydm = new FixedYDM();
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(TrancheType.JUNIOR, uint64(WAD + 1));
    }

    /// The uint64 max share is rejected by the same gate
    function test_RevertIf_InitializeShareUint64Max() public {
        FixedYDM ydm = new FixedYDM();
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(TrancheType.JUNIOR, type(uint64).max);
    }

    /// The senior tranche pays the premiums and never receives one, so no share can be initialized for it
    function test_RevertIf_InitializeForSeniorTranche() public {
        FixedYDM ydm = new FixedYDM();
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(TrancheType.SENIOR, 3e17);
    }

    /// A share of exactly WAD (the whole yield) is the largest accepted configuration
    function test_Initialize_ShareAtWadAllowed() public {
        FixedYDM ydm = new FixedYDM();
        ydm.initializeYDMForMarket(TrancheType.JUNIOR, uint64(WAD));
        assertEq(ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 0), WAD, "Y == WAD everywhere");
    }

    /// A zero share is a valid configuration: the market pays no premium, and the initialized flag
    /// keeps it distinguishable from an uninitialized market
    function test_Initialize_ZeroShareAllowed() public {
        FixedYDM ydm = new FixedYDM();
        ydm.initializeYDMForMarket(TrancheType.JUNIOR, 0);

        (bool initialized, uint64 shareWAD) = ydm.accountantToFixedYieldShare(address(this), TrancheType.JUNIOR);
        assertTrue(initialized, "the flag marks the zero share initialized");
        assertEq(shareWAD, 0, "stored share == 0");
        assertEq(ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 0), 0, "Y(0) == 0");
        assertEq(ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, WAD), 0, "Y(WAD) == 0");
        assertEq(ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.FIXED_TERM, type(uint256).max), 0, "Y is zero at any utilization and state");
    }

    /// Valid init emits FixedYdmInitialized(accountant, trancheType, share) and stores the packed state
    function test_Initialize_ReferenceShare_EmitsAndStores() public {
        FixedYDM ydm = new FixedYDM();
        vm.expectEmit(true, true, true, true, address(ydm));
        emit FixedYdmInitialized(address(this), TrancheType.JUNIOR, 3e17);
        ydm.initializeYDMForMarket(TrancheType.JUNIOR, 3e17);

        (bool initialized, uint64 shareWAD) = ydm.accountantToFixedYieldShare(address(this), TrancheType.JUNIOR);
        assertTrue(initialized, "stored initialized flag");
        assertEq(shareWAD, 3e17, "stored share");
    }

    /// Re-initialization overwrites the share in place, matching the static model's per-sender semantics
    function test_Initialize_ReinitOverwrites() public {
        FixedYDM ydm = _referenceShare();
        ydm.initializeYDMForMarket(TrancheType.JUNIOR, 7e17);
        assertEq(ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 5e17), 7e17, "the second init's share wins");
    }

    // =====================================================================
    // Yield share output: constant across utilization and market state
    // =====================================================================

    /// The fixed share ignores the utilization input completely: zero, kink-like, WAD, and above-WAD
    /// utilizations all return the configured share verbatim
    function test_YieldShare_IgnoresUtilization() public {
        FixedYDM ydm = _referenceShare();
        assertEq(ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 0), 3e17, "Y(0)");
        assertEq(ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 5e17), 3e17, "Y(0.5)");
        assertEq(ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, WAD), 3e17, "Y(WAD)");
        assertEq(ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, type(uint256).max), 3e17, "Y(uint max)");
    }

    /// The fixed share ignores the market state: PERPETUAL and FIXED_TERM read identically
    function test_YieldShare_IgnoresMarketState() public {
        FixedYDM ydm = _referenceShare();
        assertEq(ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 5e17), 3e17, "PERPETUAL");
        assertEq(ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.FIXED_TERM, 5e17), 3e17, "FIXED_TERM");
    }

    /// The mutating read returns the same share as the preview and emits YdmOutput with it
    function test_YieldShare_MatchesPreviewAndEmits() public {
        FixedYDM ydm = _referenceShare();
        uint256 previewed = ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 5e17);
        vm.expectEmit(true, true, true, true, address(ydm));
        emit YdmOutput(address(this), TrancheType.JUNIOR, 3e17);
        assertEq(ydm.yieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 5e17), previewed, "yieldShare == previewYieldShare");
    }

    // =====================================================================
    // Uninitialized market query reverts
    // =====================================================================

    /// previewYieldShare for a never-initialized accountant reverts instead of quoting a zero share
    function test_RevertIf_PreviewYieldShareUninitialized() public {
        FixedYDM ydm = new FixedYDM();
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 0);
    }

    /// yieldShare for a never-initialized accountant reverts instead of paying on a zero share
    function test_RevertIf_YieldShareUninitialized() public {
        FixedYDM ydm = new FixedYDM();
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.yieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 5e17);
    }

    /// mapping is keyed by msg.sender: A inits, B (pranked) is still uninitialized.
    function test_RevertIf_YieldShareQueriedByUninitializedAccountant() public {
        FixedYDM ydm = _referenceShare(); // address(this) initialized
        vm.prank(ACCT_B);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.yieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 0);
    }

    /// The initialized sender queries cleanly (the anti-vacuity control for the per-sender revert above)
    function test_YieldShare_InitializedSenderCanQuery() public {
        FixedYDM ydm = _referenceShare();
        assertEq(ydm.yieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 0), 3e17, "reference share Y(0)");
    }

    /// A configured zero share is not the uninitialized state: the flag disambiguates them per sender
    function test_ZeroShareInitialized_DistinctFromUninitialized() public {
        FixedYDM ydm = new FixedYDM();
        ydm.initializeYDMForMarket(TrancheType.JUNIOR, 0);
        assertEq(ydm.yieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 5e17), 0, "the initialized zero share reads zero");
        vm.prank(ACCT_B);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.yieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 5e17);
    }

    /// Shares are keyed by tranche type too: one instance serves distinct JUNIOR and LP shares for the same caller
    function test_YieldShare_PerTrancheTypeShareIsolation() public {
        FixedYDM ydm = new FixedYDM();
        ydm.initializeYDMForMarket(TrancheType.JUNIOR, 3e17);
        ydm.initializeYDMForMarket(TrancheType.LIQUIDITY_PROVIDER, 6e17);

        // Each tranche type's stored share and query output reflect its own configuration
        (bool jInit, uint64 jShare) = ydm.accountantToFixedYieldShare(address(this), TrancheType.JUNIOR);
        (bool lInit, uint64 lShare) = ydm.accountantToFixedYieldShare(address(this), TrancheType.LIQUIDITY_PROVIDER);
        assertTrue(jInit, "JUNIOR initialized");
        assertTrue(lInit, "LP initialized");
        assertEq(jShare, 3e17, "JUNIOR stored share");
        assertEq(lShare, 6e17, "LP stored share");
        assertEq(ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 5e17), 3e17, "JUNIOR share");
        assertEq(ydm.previewYieldShare(TrancheType.LIQUIDITY_PROVIDER, MarketState.PERPETUAL, 5e17), 6e17, "LP share");

        // Re-initializing the JUNIOR share must not disturb the LP share's stored state
        ydm.initializeYDMForMarket(TrancheType.JUNIOR, 1e17);
        (bool lInitAfter, uint64 lShareAfter) = ydm.accountantToFixedYieldShare(address(this), TrancheType.LIQUIDITY_PROVIDER);
        assertTrue(lInitAfter, "LP flag intact after JUNIOR re-init");
        assertEq(lShareAfter, 6e17, "LP share intact after JUNIOR re-init");
        assertEq(ydm.previewYieldShare(TrancheType.JUNIOR, MarketState.PERPETUAL, 5e17), 1e17, "JUNIOR reflects its re-init");
        assertEq(ydm.previewYieldShare(TrancheType.LIQUIDITY_PROVIDER, MarketState.PERPETUAL, 5e17), 6e17, "LP output undisturbed");
    }

    // =====================================================================
    // Fuzz: the configured share round-trips verbatim, independent of every input
    // =====================================================================

    /// Any share in [0, WAD] initializes and both reads return it verbatim at any utilization and state
    function testFuzz_YieldShare_ReturnsConfiguredShareVerbatim(uint64 share, uint256 u, uint8 stateSeed) public {
        share = uint64(bound(uint256(share), 0, WAD));
        MarketState state = (stateSeed % 2 == 0) ? MarketState.PERPETUAL : MarketState.FIXED_TERM;

        FixedYDM ydm = new FixedYDM();
        ydm.initializeYDMForMarket(TrancheType.JUNIOR, share);
        assertEq(ydm.previewYieldShare(TrancheType.JUNIOR, state, u), share, "preview returns the configured share verbatim");
        assertEq(ydm.yieldShare(TrancheType.JUNIOR, state, u), share, "yieldShare returns the configured share verbatim");
    }

    /// Any share above WAD is rejected by the initialization gate
    function testFuzz_RevertIf_InitializeShareAboveWad(uint64 share) public {
        share = uint64(bound(uint256(share), WAD + 1, type(uint64).max));
        FixedYDM ydm = new FixedYDM();
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(TrancheType.JUNIOR, share);
    }
}
