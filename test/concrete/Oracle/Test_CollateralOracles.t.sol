// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { NAV_UNIT, toUint256 } from "../../../src/libraries/Units.sol";
import { ERC4626SharePriceOracle } from "../../../src/oracle/ERC4626SharePriceOracle.sol";
import { IdleCDOTranchePriceOracle } from "../../../src/oracle/IdleCDOTranchePriceOracle.sol";
import { MakinaSharePriceOracle } from "../../../src/oracle/MakinaSharePriceOracle.sol";
import { ChainlinkPriceOracleBase } from "../../../src/oracle/base/ChainlinkPriceOracleBase.sol";
import { OracleClockBase } from "../../../src/oracle/base/clock/OracleClockBase.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockERC4626C } from "../../mocks/MockERC4626C.sol";
import { MockIdleCDO } from "../../mocks/MockIdleCDO.sol";
import { MockMakinaMachine } from "../../mocks/MockMakinaMachine.sol";
import { UninitializedERC1967Proxy } from "../../mocks/UninitializedERC1967Proxy.sol";

/**
 * @title Test_CollateralOracles
 * @notice Concrete vectors for the three production price oracles: the composed getPrice math with hand-derived floors,
 *         the updatedAt sourcing per oracle class, the poke and previewPoke clock semantics, and the construction
 *         sanity checks
 * @dev Every expected value is derived by hand from the composition definition, never captured from the oracle
 */
contract Test_CollateralOracles is Test {
    /// @dev Base timestamp so poke and update timestamps assert against stable absolute values
    uint256 internal constant T0 = 1_700_000_000;

    MockERC20C internal referenceAsset;
    MockERC4626C internal vault;
    MockAggregatorV3 internal feed;
    ERC4626SharePriceOracle internal erc4626Oracle;

    MockERC20C internal machineShare;
    MockMakinaMachine internal machine;
    MakinaSharePriceOracle internal makinaOracle;

    MockERC20C internal aaTranche;
    MockERC20C internal cdoUnderlying;
    MockIdleCDO internal cdo;
    AccessManager internal authority;
    IdleCDOTranchePriceOracle internal cdoOracle;

    function setUp() public {
        vm.warp(T0);
        authority = new AccessManager(address(this));

        // ERC4626: an 18-decimal share over a 6-decimal reference asset, priced by an 8-decimal feed
        referenceAsset = new MockERC20C("NUSD", "NUSD", 6);
        vault = new MockERC4626C(address(referenceAsset), "Staked NUSD", "sNUSD", 18);
        feed = new MockAggregatorV3(8, 1e8);
        erc4626Oracle = new ERC4626SharePriceOracle(address(vault), address(feed));

        // Makina: an 18-decimal share over a 6-decimal accounting asset, sharing the same feed shape
        machineShare = new MockERC20C("DUSD", "DUSD", 18);
        MockERC20C accountingAsset = new MockERC20C("USDC", "USDC", 6);
        machine = new MockMakinaMachine(address(machineShare), address(accountingAsset), 1e18);
        makinaOracle = new MakinaSharePriceOracle(address(machine), address(feed));

        // Idle CDO: an AA tranche over a 6-decimal underlying, virtual price in underlying decimals, composed
        // with the shared feed and proxied like every RoycoBase contract with a zero deviation threshold
        aaTranche = new MockERC20C("AA_FalconXUSDC", "AA_FalconXUSDC", 18);
        cdoUnderlying = new MockERC20C("USDC", "USDC", 6);
        cdo = new MockIdleCDO(address(aaTranche), address(cdoUnderlying), 1.01e6);
        cdoOracle = _deployCDOOracle(address(aaTranche), 0);
    }

    /// @dev Deploys the CDO tranche price oracle for the tranche behind a proxy with the specified deviation threshold
    function _deployCDOOracle(address _tranche, uint256 _minDeviationWAD) internal returns (IdleCDOTranchePriceOracle oracle) {
        IdleCDOTranchePriceOracle implementation = new IdleCDOTranchePriceOracle(address(cdo), _tranche, address(feed));
        oracle = IdleCDOTranchePriceOracle(address(new UninitializedERC1967Proxy(address(implementation))));
        oracle.initialize(address(authority), _minDeviationWAD, 0);
    }

    /*----------------------------------------------------------------------
                        ERC4626SharePriceOracle
    ----------------------------------------------------------------------*/

    /**
     * The composed price is the live share price times the feed price in a single floored mulDiv
     * Derivation: share rate 1.05e18 (1 share = 1.05 NUSD) and feed 0.99e8 (1 NUSD = 0.99 NAV units at 8
     * decimals): price = floor(1.05e18 * 99000000 / 1e8) = 1.0395e18 exact, at the oracle's WAD decimals
     */
    function test_ERC4626_composesSharePriceWithFeed() public {
        vault.setRate(1.05e18);
        feed.setAnswer(0.99e8);
        (NAV_UNIT price,) = erc4626Oracle.getPrice();
        assertEq(toUint256(price), 1.0395e18, "composed price must be the share rate times the feed price");
        assertEq(erc4626Oracle.decimals(), 18, "prices are reported at WAD precision");
    }

    /**
     * The single-mulDiv composition floors exactly once
     * Derivation: share rate 1e18+3 and feed 1.23456789e8: price = floor((1e18+3) * 123456789 / 1e8)
     * = 123456789e10 + floor(3 * 123456789 / 1e8) = 1234567890000000000 + 3 = 1234567890000000003
     */
    function test_ERC4626_compositionFloorsOnce() public {
        vault.setRate(1e18 + 3);
        feed.setAnswer(1.23456789e8);
        (NAV_UNIT price,) = erc4626Oracle.getPrice();
        assertEq(toUint256(price), 1_234_567_890_000_000_003, "the composition floors the full product once");
    }

    /// The share hop is always current, so the feed's update timestamp passes through unchanged next to the composed price
    function test_ERC4626_feedUpdatedAtPassesThrough() public {
        vault.setRate(1e18);
        feed.setAll(7, 2e8, T0 - 50, T0 - 10, 9);
        (NAV_UNIT price, uint256 updatedAt) = erc4626Oracle.getPrice();
        assertEq(toUint256(price), 2e18, "the composed price replaces the feed answer");
        assertEq(updatedAt, T0 - 10, "the feed updatedAt passes through: the live share hop is always current");
    }

    /// poke and previewPoke report the feed's update timestamp: the oracle network timestamps its own updates
    function test_ERC4626_pokeReportsFeedUpdatedAt() public {
        feed.setUpdatedAt(T0 - 123);
        assertEq(erc4626Oracle.poke(), T0 - 123, "poke must pass the feed's update timestamp");
        assertEq(erc4626Oracle.previewPoke(), T0 - 123, "previewPoke must agree with poke on a timestamp-forwarding oracle");
    }

    /// A non-positive feed price cannot compose into an honest collateral price
    function test_RevertIf_ERC4626_feedAnswerNonPositive() public {
        feed.setAnswer(0);
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_PRICE.selector);
        erc4626Oracle.getPrice();
        feed.setAnswer(-1);
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_PRICE.selector);
        erc4626Oracle.getPrice();
    }

    /// A round answered before it started is carrying a stale answer forward, so the composition refuses it
    function test_RevertIf_ERC4626_feedRoundIncomplete() public {
        feed.setAll(7, 1e8, T0 - 50, T0 - 10, 6);
        vm.expectRevert(ChainlinkPriceOracleBase.INCOMPLETE_PRICE.selector);
        erc4626Oracle.getPrice();
    }

    /// Construction wires the collateral identity and rejects null configuration
    function test_ERC4626_constructionIdentityAndNullChecks() public {
        assertEq(erc4626Oracle.COLLATERAL_ASSET(), address(vault), "the collateral asset is the vault share");
        assertEq(address(erc4626Oracle.ORACLE()), address(feed), "the feed is wired");
        assertEq(erc4626Oracle.version(), 1, "version");
        assertEq(
            erc4626Oracle.description(), string.concat("sNUSD / ", feed.description()), "the description reads as the triangulated pair chain through the feed"
        );
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ERC4626SharePriceOracle(address(0), address(feed));
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ERC4626SharePriceOracle(address(vault), address(0));
    }

    /*----------------------------------------------------------------------
                        MakinaSharePriceOracle
    ----------------------------------------------------------------------*/

    /**
     * The composed price is the live machine share price times the feed price
     * Derivation: machine share price 1.02e18 (1 DUSD = 1.02 USDC) and feed 1.00005e8: price =
     * floor(1.02e18 * 100005000 / 1e8) = 1.020051e18 exact
     */
    function test_Makina_composesSharePriceWithFeed() public {
        machine.setSharePriceWAD(1.02e18);
        feed.setAnswer(1.00005e8);
        (NAV_UNIT price,) = makinaOracle.getPrice();
        assertEq(toUint256(price), 1.020051e18, "composed price must be the machine share price times the feed price");
    }

    /// The collateral asset resolves from the machine at construction so the pairing can never mismatch
    function test_Makina_collateralAssetResolvesFromMachine() public view {
        assertEq(makinaOracle.COLLATERAL_ASSET(), address(machineShare), "the collateral asset is the machine's share token");
        assertEq(makinaOracle.MAKINA_MACHINE(), address(machine), "the machine is wired");
    }

    /// A share price drawdown composes downward exactly
    /// Derivation: machine share price 0.98e18 and feed 1.00005e8: price = floor(0.98e18 * 100005000 / 1e8) = 0.980049e18
    function test_Makina_drawdownComposesExactly() public {
        machine.setSharePriceWAD(0.98e18);
        feed.setAnswer(1.00005e8);
        (NAV_UNIT price,) = makinaOracle.getPrice();
        assertEq(toUint256(price), 0.980049e18, "the drawdown composes through the same floored product");
    }

    /*----------------------------------------------------------------------
                        IdleCDOTranchePriceOracle
    ----------------------------------------------------------------------*/

    /**
     * The composed price is the live virtual price times the feed price, but updatedAt comes from the clock
     * Derivation: virtual price 1.01e6 at the 6-decimal underlying lifts by 1e12 to 1.01e18 and feed 1.00005e8:
     * price = floor(1.01e18 * 100005000 / 1e8) = 1.0100505e18 exact. The virtual price still sits at the
     * initialization baseline, so previewPoke and therefore updatedAt report the zero checkpoint, not the feed's T0-10
     */
    function test_IdleCDO_composesVirtualPriceWithFeed() public {
        feed.setAll(7, 1.00005e8, T0 - 50, T0 - 10, 9);
        (NAV_UNIT price, uint256 updatedAt) = cdoOracle.getPrice();
        assertEq(toUint256(price), 1.0100505e18, "composed price must be the virtual price times the feed price");
        assertEq(updatedAt, 0, "updatedAt is the clock's checkpoint, never the feed's timestamp");
        assertEq(cdoOracle.decimals(), 18, "prices are reported at WAD precision");
    }

    /**
     * The two clock questions split across the two legs: a feed heartbeat alone never advances poke, only a
     * virtual price deviation does, and getPrice's updatedAt keeps tracking the clock instead of the feed
     */
    function test_IdleCDO_pokeKeysOnVirtualPriceNotTheFeed() public {
        assertEq(cdoOracle.poke(), 0, "the initialization baseline carries no update timestamp");

        // A fresh feed heartbeat is invisible to the clock: the tranche price has not moved
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 100);
        assertEq(cdoOracle.poke(), 0, "a feed heartbeat alone must never open the execution gate");

        // A virtual price move checkpoints the clock at the wall-clock time it was observed, and the checkpoint persists
        cdo.setVirtualPrice(1.02e6);
        assertEq(cdoOracle.poke(), T0 + 100, "a virtual price deviation checkpoints the clock");
        vm.warp(T0 + 200);
        assertEq(cdoOracle.poke(), T0 + 100, "the checkpoint persists until the next observed change");

        // A later feed heartbeat leaves getPrice's updatedAt pinned at the clock checkpoint
        feed.setUpdatedAt(T0 + 142);
        (, uint256 updatedAt) = cdoOracle.getPrice();
        assertEq(updatedAt, T0 + 100, "updatedAt tracks the virtual price clock while the feed moves freely");
    }

    /**
     * previewPoke reports the deviation it observes at the current timestamp without committing a checkpoint, so an
     * uncommitted deviation keeps reporting the live block.timestamp until a poke commits it
     */
    function test_IdleCDO_previewPokeReportsWithoutCommitting() public {
        vm.warp(T0 + 100);
        assertEq(cdoOracle.previewPoke(), 0, "an unchanged virtual price reports the stored zero checkpoint");

        // An observed deviation reports the current timestamp exactly as a poke would stamp it
        cdo.setVirtualPrice(1.02e6);
        assertEq(cdoOracle.previewPoke(), T0 + 100, "a deviation previews the current timestamp");

        // Nothing was committed, so the same deviation re-previews at the new current timestamp
        vm.warp(T0 + 200);
        assertEq(cdoOracle.previewPoke(), T0 + 200, "an uncommitted deviation floats with block.timestamp");
        // getPrice reports the OLDER hop: the feed was stamped at construction (T0), older than the floating clock
        (, uint256 updatedAt) = cdoOracle.getPrice();
        assertEq(updatedAt, T0, "getPrice's updatedAt is the older of the feed and the clock");
        // With a feed stamped fresher than the clock, the clock becomes the older hop and getPrice reports it
        feed.setUpdatedAt(T0 + 300);
        (, updatedAt) = cdoOracle.getPrice();
        assertEq(updatedAt, T0 + 200, "getPrice's updatedAt is the older of the feed and the clock");
        feed.setUpdatedAt(T0);

        // A poke commits the checkpoint, after which previewPoke reports the stored value
        assertEq(cdoOracle.poke(), T0 + 200, "the poke commits the floating deviation");
        vm.warp(T0 + 300);
        assertEq(cdoOracle.previewPoke(), T0 + 200, "after the commit the stored checkpoint is reported");
    }

    /**
     * A configured deviation threshold mutes sub-threshold noise on the virtual price and checkpoints at the boundary
     * Derivation (threshold 1%): from the 1.01e6 baseline a move to 1.015e6 is ~0.495% (muted) and a move to
     * 1.0201e6 is exactly 1% (floor(1e18 * 10100 / 1010000) = 1e16 >= threshold, checkpointed)
     */
    function test_IdleCDO_deviationThresholdGatesTheClock() public {
        IdleCDOTranchePriceOracle gated = _deployCDOOracle(address(aaTranche), 0.01e18);
        vm.warp(T0 + 100);
        cdo.setVirtualPrice(1.015e6);
        assertEq(gated.poke(), 0, "a sub-threshold move never counts as an update");
        cdo.setVirtualPrice(1.0201e6);
        assertEq(gated.poke(), T0 + 100, "a move at the threshold checkpoints");
    }

    /// Construction wires the collateral identity against the CDO and rejects null or non-member configuration
    function test_IdleCDO_constructionIdentityAndNullChecks() public {
        assertEq(cdoOracle.COLLATERAL_ASSET(), address(aaTranche), "the collateral asset is the configured CDO tranche");
        assertEq(cdoOracle.IDLE_CDO(), address(cdo), "the CDO is wired");
        assertEq(address(cdoOracle.ORACLE()), address(feed), "the feed is wired");
        assertEq(cdoOracle.version(), 1, "version");
        assertEq(cdoOracle.description(), string.concat("AA_FalconXUSDC / ", feed.description()), "the description chains through the feed");
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new IdleCDOTranchePriceOracle(address(0), address(aaTranche), address(feed));
        // The CDO's virtualPrice silently computes the BB price for any unknown address, so membership is checked
        vm.expectRevert(IdleCDOTranchePriceOracle.COLLATERAL_ASSET_MUST_BE_CDO_TRANCHE.selector);
        new IdleCDOTranchePriceOracle(address(cdo), makeAddr("NOT_A_TRANCHE"), address(feed));
    }

    /// The oracle prices the BB (junior) tranche identically: virtualPrice works for either CDO tranche
    function test_IdleCDO_pricesTheBBTranche() public {
        MockERC20C bbTranche = new MockERC20C("BB_FalconXUSDC", "BB_FalconXUSDC", 18);
        cdo.setBBTranche(address(bbTranche));
        IdleCDOTranchePriceOracle bbOracle = _deployCDOOracle(address(bbTranche), 0);
        assertEq(bbOracle.COLLATERAL_ASSET(), address(bbTranche), "the collateral asset is the BB tranche");
        (NAV_UNIT price,) = bbOracle.getPrice();
        assertEq(toUint256(price), 1.01e18, "the BB tranche's virtual price composes identically at the unit feed price");
        assertEq(bbOracle.description(), string.concat("BB_FalconXUSDC / ", feed.description()), "the description reads the BB chain");
    }

    /// The proxy initializes exactly once
    function test_RevertIf_IdleCDO_initializedTwice() public {
        vm.expectRevert();
        cdoOracle.initialize(address(authority), 0, 0);
    }

    /// An attested initialization checkpoint seeds the clock, and a future one fails shut
    function test_IdleCDO_initializationCheckpointSeedsTheClock() public {
        IdleCDOTranchePriceOracle implementation = new IdleCDOTranchePriceOracle(address(cdo), address(aaTranche), address(feed));
        IdleCDOTranchePriceOracle seeded = IdleCDOTranchePriceOracle(address(new UninitializedERC1967Proxy(address(implementation))));
        seeded.initialize(address(authority), 0, uint32(T0 - 100));
        assertEq(seeded.poke(), T0 - 100, "the attested checkpoint is the clock's starting update");

        IdleCDOTranchePriceOracle future = IdleCDOTranchePriceOracle(address(new UninitializedERC1967Proxy(address(implementation))));
        vm.expectRevert(OracleClockBase.INVALID_LAST_UPDATE_TIMESTAMP.selector);
        future.initialize(address(authority), 0, uint32(T0 + 1));
    }

    /// The restricted tick escape hatch is inherited: an attested update unblocks the deviation blind spot
    function test_IdleCDO_tickInherited() public {
        address anyone = makeAddr("ANYONE");
        vm.prank(anyone);
        vm.expectRevert();
        cdoOracle.tick();
        vm.warp(T0 + 100);
        cdoOracle.tick();
        assertEq(cdoOracle.poke(), T0 + 100, "the attested update stamps the clock");
    }
}
