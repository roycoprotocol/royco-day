// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { SafeCast } from "../../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IIdleCDO } from "../../../src/interfaces/external/idle-finance/IIdleCDO.sol";
import { ERC4626CollateralOracle } from "../../../src/oracle/ERC4626CollateralOracle.sol";
import { IdleCDOCollateralOracle } from "../../../src/oracle/IdleCDOCollateralOracle.sol";
import { MakinaCollateralOracle } from "../../../src/oracle/MakinaCollateralOracle.sol";
import { ChainlinkCollateralOracleBase } from "../../../src/oracle/base/ChainlinkCollateralOracleBase.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockERC4626C } from "../../mocks/MockERC4626C.sol";
import { MockIdleCDO } from "../../mocks/MockIdleCDO.sol";
import { MockMakinaMachine } from "../../mocks/MockMakinaMachine.sol";
import { UninitializedERC1967Proxy } from "../../mocks/UninitializedERC1967Proxy.sol";

/**
 * @title Test_CollateralOracles
 * @notice Concrete vectors for the three collateral oracles: the composed price math with hand-derived floors,
 *         the round-data passthrough and always-fresh shapes, the poke clock semantics per source class, and the
 *         construction sanity checks
 * @dev Every expected value is derived by hand from the composition definition, never captured from the oracle
 */
contract Test_CollateralOracles is Test {
    /// @dev Base timestamp so poke and round timestamps assert against stable absolute values
    uint256 internal constant T0 = 1_700_000_000;

    MockERC20C internal referenceAsset;
    MockERC4626C internal vault;
    MockAggregatorV3 internal feed;
    ERC4626CollateralOracle internal erc4626Oracle;

    MockERC20C internal machineShare;
    MockMakinaMachine internal machine;
    MakinaCollateralOracle internal makinaOracle;

    MockERC20C internal aaTranche;
    MockERC20C internal cdoUnderlying;
    MockIdleCDO internal cdo;
    AccessManager internal authority;
    IdleCDOCollateralOracle internal cdoOracle;

    function setUp() public {
        vm.warp(T0);
        authority = new AccessManager(address(this));

        // ERC4626: an 18-decimal share over a 6-decimal reference asset, priced by an 8-decimal feed
        referenceAsset = new MockERC20C("NUSD", "NUSD", 6);
        vault = new MockERC4626C(address(referenceAsset), "Staked NUSD", "sNUSD", 18);
        feed = new MockAggregatorV3(8, 1e8);
        erc4626Oracle = new ERC4626CollateralOracle(address(vault), address(feed));

        // Makina: an 18-decimal share over a 6-decimal accounting asset, sharing the same feed shape
        machineShare = new MockERC20C("DUSD", "DUSD", 18);
        MockERC20C accountingAsset = new MockERC20C("USDC", "USDC", 6);
        machine = new MockMakinaMachine(address(machineShare), address(accountingAsset), 1e18);
        makinaOracle = new MakinaCollateralOracle(address(machine), address(feed));

        // Idle CDO: an AA tranche over a 6-decimal underlying, virtual price in underlying decimals, composed
        // with the shared feed and proxied like every RoycoBase contract with a zero deviation threshold
        aaTranche = new MockERC20C("AA_FalconXUSDC", "AA_FalconXUSDC", 18);
        cdoUnderlying = new MockERC20C("USDC", "USDC", 6);
        cdo = new MockIdleCDO(address(aaTranche), address(cdoUnderlying), 1.01e6);
        cdoOracle = _deployCDOOracle(address(aaTranche), 0);
    }

    /// @dev Deploys the CDO collateral oracle for the tranche behind a proxy with the specified deviation threshold
    function _deployCDOOracle(address _tranche, uint256 _minDeviationWAD) internal returns (IdleCDOCollateralOracle oracle) {
        IdleCDOCollateralOracle implementation = new IdleCDOCollateralOracle(address(cdo), _tranche, address(feed));
        oracle = IdleCDOCollateralOracle(address(new UninitializedERC1967Proxy(address(implementation))));
        oracle.initialize(address(authority), _minDeviationWAD);
    }

    /*----------------------------------------------------------------------
                        ERC4626CollateralOracle
    ----------------------------------------------------------------------*/

    /**
     * The composed answer is the live share price times the feed price in a single floored mulDiv
     * Derivation: share rate 1.05e18 (1 share = 1.05 NUSD) and feed 0.99e8 (1 NUSD = 0.99 NAV units at 8
     * decimals): answer = floor(1.05e18 * 99000000 / 1e8) = 1.0395e18 exact, at the oracle's WAD decimals
     */
    function test_ERC4626_composesSharePriceWithFeed() public {
        vault.setRate(1.05e18);
        feed.setAnswer(0.99e8);
        (, int256 answer,,,) = erc4626Oracle.latestRoundData();
        assertEq(answer, 1.0395e18, "composed answer must be the share rate times the feed price");
        assertEq(erc4626Oracle.decimals(), 18, "answers are reported at WAD precision");
    }

    /**
     * The single-mulDiv composition floors exactly once
     * Derivation: share rate 1e18+3 and feed 1.23456789e8: answer = floor((1e18+3) * 123456789 / 1e8)
     * = 123456789e10 + floor(3 * 123456789 / 1e8) = 1234567890000000000 + 3 = 1234567890000000003
     */
    function test_ERC4626_compositionFloorsOnce() public {
        vault.setRate(1e18 + 3);
        feed.setAnswer(1.23456789e8);
        (, int256 answer,,,) = erc4626Oracle.latestRoundData();
        assertEq(answer, 1_234_567_890_000_000_003, "the composition floors the full product once");
    }

    /// The share hop is always current, so the feed's round data passes through unchanged around the composed answer
    function test_ERC4626_feedRoundDataPassesThrough() public {
        vault.setRate(1e18);
        feed.setAll(7, 2e8, T0 - 50, T0 - 10, 9);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = erc4626Oracle.latestRoundData();
        assertEq(roundId, 7, "the feed round id passes through");
        assertEq(answer, 2e18, "the composed answer replaces the feed answer");
        assertEq(startedAt, T0 - 50, "the feed startedAt passes through");
        assertEq(updatedAt, T0 - 10, "the feed updatedAt passes through: the live share hop is always current");
        assertEq(answeredInRound, 9, "the feed answeredInRound passes through");
    }

    /// poke reports the feed's update timestamp: the oracle network timestamps its own updates
    function test_ERC4626_pokeReportsFeedUpdatedAt() public {
        feed.setUpdatedAt(T0 - 123);
        assertEq(erc4626Oracle.poke(), uint32(T0 - 123), "poke must pass the feed's update timestamp");
    }

    /// poke fails loudly on a timestamp past the uint32 range instead of truncating garbage
    function test_RevertIf_ERC4626_pokeTimestampOverflowsUint32() public {
        feed.setUpdatedAt(uint256(type(uint32).max) + 1);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 32, uint256(type(uint32).max) + 1));
        erc4626Oracle.poke();
    }

    /// A non-positive feed price cannot compose into an honest collateral price
    function test_RevertIf_ERC4626_feedAnswerNonPositive() public {
        feed.setAnswer(0);
        vm.expectRevert(ChainlinkCollateralOracleBase.INVALID_PRICE.selector);
        erc4626Oracle.latestRoundData();
        feed.setAnswer(-1);
        vm.expectRevert(ChainlinkCollateralOracleBase.INVALID_PRICE.selector);
        erc4626Oracle.latestRoundData();
    }

    /// The live conversion hop cannot be reconstructed for a past round
    function test_RevertIf_ERC4626_historicalRoundQueried() public {
        vm.expectRevert(bytes("No data present"));
        erc4626Oracle.getRoundData(1);
    }

    /// Construction wires the collateral identity and rejects null configuration
    function test_ERC4626_constructionIdentityAndNullChecks() public {
        assertEq(erc4626Oracle.COLLATERAL_ASSET(), address(vault), "the collateral asset is the vault share");
        assertEq(address(erc4626Oracle.ORACLE()), address(feed), "the feed is wired");
        assertEq(erc4626Oracle.version(), 1, "version");
        assertEq(
            erc4626Oracle.description(),
            string.concat("sNUSD / ", feed.description()),
            "the description reads as the triangulated pair chain through the feed"
        );
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ERC4626CollateralOracle(address(0), address(feed));
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ERC4626CollateralOracle(address(vault), address(0));
    }

    /*----------------------------------------------------------------------
                        MakinaCollateralOracle
    ----------------------------------------------------------------------*/

    /**
     * The composed answer is the live machine share price times the feed price
     * Derivation: machine share price 1.02e18 (1 DUSD = 1.02 USDC) and feed 1.00005e8: answer =
     * floor(1.02e18 * 100005000 / 1e8) = 1.020051e18 exact
     */
    function test_Makina_composesSharePriceWithFeed() public {
        machine.setSharePriceWAD(1.02e18);
        feed.setAnswer(1.00005e8);
        (, int256 answer,,,) = makinaOracle.latestRoundData();
        assertEq(answer, 1.020051e18, "composed answer must be the machine share price times the feed price");
    }

    /// The collateral asset resolves from the machine at construction so the pairing can never mismatch
    function test_Makina_collateralAssetResolvesFromMachine() public view {
        assertEq(makinaOracle.COLLATERAL_ASSET(), address(machineShare), "the collateral asset is the machine's share token");
        assertEq(makinaOracle.MAKINA_MACHINE(), address(machine), "the machine is wired");
    }

    /// A share price drawdown composes downward exactly
    /// Derivation: machine share price 0.98e18 and feed 1.00005e8: answer = floor(0.98e18 * 100005000 / 1e8) = 0.980049e18
    function test_Makina_drawdownComposesExactly() public {
        machine.setSharePriceWAD(0.98e18);
        feed.setAnswer(1.00005e8);
        (, int256 answer,,,) = makinaOracle.latestRoundData();
        assertEq(answer, 0.980049e18, "the drawdown composes through the same floored product");
    }

    /*----------------------------------------------------------------------
                        IdleCDOCollateralOracle
    ----------------------------------------------------------------------*/

    /**
     * The composed answer is the live virtual price times the feed price
     * Derivation: virtual price 1.01e6 at the 6-decimal underlying lifts by 1e12 to 1.01e18 and feed 1.00005e8:
     * answer = floor(1.01e18 * 100005000 / 1e8) = 1.0100505e18 exact, with the feed's round data passing through
     */
    function test_IdleCDO_composesVirtualPriceWithFeed() public {
        feed.setAll(7, 1.00005e8, T0 - 50, T0 - 10, 9);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = cdoOracle.latestRoundData();
        assertEq(answer, 1.0100505e18, "composed answer must be the virtual price times the feed price");
        assertEq(roundId, 7, "the feed round id passes through");
        assertEq(updatedAt, T0 - 10, "staleness keys on the feed: the virtual price hop is always current");
        assertEq(answeredInRound, 9, "the feed answeredInRound passes through");
        assertEq(cdoOracle.decimals(), 18, "answers are reported at WAD precision");
    }

    /**
     * The two clock questions split across the two legs: a feed heartbeat alone never advances poke, only a
     * virtual price deviation does, while the report's updatedAt keeps tracking the feed
     */
    function test_IdleCDO_pokeKeysOnVirtualPriceNotTheFeed() public {
        assertEq(cdoOracle.poke(), 0, "the initialization baseline carries no update timestamp");

        // A fresh feed heartbeat is invisible to the clock: the tranche price has not moved
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 100);
        assertEq(cdoOracle.poke(), 0, "a feed heartbeat alone must never open the execution gate");

        // A virtual price move checkpoints the clock at the wall-clock time it was observed, and the checkpoint persists
        cdo.setVirtualPrice(1.02e6);
        assertEq(cdoOracle.poke(), uint32(T0 + 100), "a virtual price deviation checkpoints the clock");
        vm.warp(T0 + 200);
        assertEq(cdoOracle.poke(), uint32(T0 + 100), "the checkpoint persists until the next observed change");

        // The report's updatedAt still keys on the feed leg, independent of the clock
        feed.setUpdatedAt(T0 + 42);
        (,,, uint256 updatedAt,) = cdoOracle.latestRoundData();
        assertEq(updatedAt, T0 + 42, "updatedAt tracks the feed while poke tracks the virtual price");
    }

    /**
     * A configured deviation threshold mutes sub-threshold noise on the virtual price and checkpoints at the boundary
     * Derivation (threshold 1%): from the 1.01e6 baseline a move to 1.015e6 is ~0.495% (muted) and a move to
     * 1.0201e6 is exactly 1% (floor(1e18 * 10100 / 1010000) = 1e16 >= threshold, checkpointed)
     */
    function test_IdleCDO_deviationThresholdGatesTheClock() public {
        IdleCDOCollateralOracle gated = _deployCDOOracle(address(aaTranche), 0.01e18);
        vm.warp(T0 + 100);
        cdo.setVirtualPrice(1.015e6);
        assertEq(gated.poke(), 0, "a sub-threshold move never counts as an update");
        cdo.setVirtualPrice(1.0201e6);
        assertEq(gated.poke(), uint32(T0 + 100), "a move at the threshold checkpoints");
    }

    /// Construction wires the collateral identity against the CDO and rejects null or non-member configuration
    function test_IdleCDO_constructionIdentityAndNullChecks() public {
        assertEq(cdoOracle.COLLATERAL_ASSET(), address(aaTranche), "the collateral asset is the configured CDO tranche");
        assertEq(cdoOracle.IDLE_CDO(), address(cdo), "the CDO is wired");
        assertEq(address(cdoOracle.ORACLE()), address(feed), "the feed is wired");
        assertEq(cdoOracle.version(), 1, "version");
        assertEq(cdoOracle.description(), string.concat("AA_FalconXUSDC / ", feed.description()), "the description chains through the feed");
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new IdleCDOCollateralOracle(address(0), address(aaTranche), address(feed));
        // The CDO's virtualPrice silently computes the BB price for any unknown address, so membership is checked
        vm.expectRevert(IdleCDOCollateralOracle.COLLATERAL_ASSET_MUST_BE_CDO_TRANCHE.selector);
        new IdleCDOCollateralOracle(address(cdo), makeAddr("NOT_A_TRANCHE"), address(feed));
    }

    /// The oracle prices the BB (junior) tranche identically: virtualPrice works for either CDO tranche
    function test_IdleCDO_pricesTheBBTranche() public {
        MockERC20C bbTranche = new MockERC20C("BB_FalconXUSDC", "BB_FalconXUSDC", 18);
        cdo.setBBTranche(address(bbTranche));
        IdleCDOCollateralOracle bbOracle = _deployCDOOracle(address(bbTranche), 0);
        assertEq(bbOracle.COLLATERAL_ASSET(), address(bbTranche), "the collateral asset is the BB tranche");
        (, int256 answer,,,) = bbOracle.latestRoundData();
        assertEq(answer, 1.01e18, "the BB tranche's virtual price composes identically at the unit feed price");
        assertEq(bbOracle.description(), string.concat("BB_FalconXUSDC / ", feed.description()), "the description reads the BB chain");
    }

    /// The live virtual price hop cannot be reconstructed for a past round
    function test_RevertIf_IdleCDO_historicalRoundQueried() public {
        vm.expectRevert(bytes("No data present"));
        cdoOracle.getRoundData(1);
    }

    /// The proxy initializes exactly once
    function test_RevertIf_IdleCDO_initializedTwice() public {
        vm.expectRevert();
        cdoOracle.initialize(address(authority), 0);
    }

    /// The restricted tick escape hatch is inherited: an attested update unblocks the deviation blind spot
    function test_IdleCDO_tickInherited() public {
        address anyone = makeAddr("ANYONE");
        vm.prank(anyone);
        vm.expectRevert();
        cdoOracle.tick();
        vm.warp(T0 + 100);
        cdoOracle.tick();
        assertEq(cdoOracle.poke(), uint32(T0 + 100), "the attested update stamps the clock");
    }
}