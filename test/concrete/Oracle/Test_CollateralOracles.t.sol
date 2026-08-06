// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { NAV_UNIT, toUint256 } from "../../../src/libraries/Units.sol";
import { ERC4626SharePriceOracle } from "../../../src/oracle/ERC4626SharePriceOracle.sol";
import { IdleCDOTranchePriceOracle } from "../../../src/oracle/IdleCDOTranchePriceOracle.sol";
import { MakinaSharePriceOracle } from "../../../src/oracle/MakinaSharePriceOracle.sol";
import { ChainlinkPriceOracleBase } from "../../../src/oracle/base/ChainlinkPriceOracleBase.sol";
import { ClockedChainlinkPriceOracleBase } from "../../../src/oracle/base/ClockedChainlinkPriceOracleBase.sol";
import { OracleClockBase } from "../../../src/oracle/base/clock/OracleClockBase.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockERC4626C } from "../../mocks/MockERC4626C.sol";
import { MockIdleCDO } from "../../mocks/MockIdleCDO.sol";
import { MockMakinaMachine } from "../../mocks/MockMakinaMachine.sol";

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

    /// @dev The per-hop staleness immutables the suite constructs with: the feed hop tight, the CDO clock and
    ///      Makina accounting hops wide, so the gates can be crossed independently
    uint32 internal constant FEED_STALENESS = 1 days;
    uint32 internal constant CDO_PRICE_STALENESS = 30 days;
    uint32 internal constant MAKINA_ACCOUNTING_STALENESS = 2 days;
    uint32 internal constant VAULT_SHARE_PRICE_STALENESS = 3 days;

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
    IdleCDOTranchePriceOracle internal cdoOracle;

    function setUp() public {
        vm.warp(T0);

        // ERC4626: an 18-decimal share over a 6-decimal reference asset, priced by an 8-decimal feed
        referenceAsset = new MockERC20C("NUSD", "NUSD", 6);
        vault = new MockERC4626C(address(referenceAsset), "Staked NUSD", "sNUSD", 18);
        feed = new MockAggregatorV3(8, 1e8);
        erc4626Oracle = new ERC4626SharePriceOracle(
            address(vault),
            ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS,
            address(feed),
            0,
            uint32(T0),
            FEED_STALENESS,
            VAULT_SHARE_PRICE_STALENESS
        );

        // Makina: an 18-decimal share over a 6-decimal accounting asset, sharing the same feed shape
        machineShare = new MockERC20C("DUSD", "DUSD", 18);
        MockERC20C accountingAsset = new MockERC20C("USDC", "USDC", 6);
        machine = new MockMakinaMachine(address(machineShare), address(accountingAsset), 1e18);
        makinaOracle = new MakinaSharePriceOracle(address(machine), address(feed), FEED_STALENESS, MAKINA_ACCOUNTING_STALENESS);

        // Idle CDO: an AA tranche over a 6-decimal underlying, virtual price in underlying decimals, composed
        // with the shared feed as a fully immutable direct deployment with a zero deviation threshold
        aaTranche = new MockERC20C("AA_FalconXUSDC", "AA_FalconXUSDC", 18);
        cdoUnderlying = new MockERC20C("USDC", "USDC", 6);
        cdo = new MockIdleCDO(address(aaTranche), address(cdoUnderlying), 1.01e6);
        cdoOracle = _deployCDOOracle(address(aaTranche), 0);
    }

    /// @dev Deploys the CDO tranche price oracle for the tranche with the specified deviation threshold and no attested checkpoint
    function _deployCDOOracle(address _tranche, uint256 _minDeviationWAD) internal returns (IdleCDOTranchePriceOracle oracle) {
        return new IdleCDOTranchePriceOracle(address(cdo), _tranche, address(feed), _minDeviationWAD, 0, FEED_STALENESS, CDO_PRICE_STALENESS);
    }

    /// @dev Deploys the CDO oracle with an attested clock checkpoint, so getPrice's virtual-price hop starts FRESH
    ///      (an unattested zero checkpoint holds pricing shut under the source staleness gate)
    function _deploySeededCDOOracle(address _tranche, uint32 _lastUpdate) internal returns (IdleCDOTranchePriceOracle oracle) {
        return new IdleCDOTranchePriceOracle(address(cdo), _tranche, address(feed), 0, _lastUpdate, FEED_STALENESS, CDO_PRICE_STALENESS);
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
     * PREVIEW_REDEEM mode prices shares at their realizable redemption value, not the nominal exchange rate
     * Derivation: share rate 1.05e18 with a 2% redemption haircut and feed 1e8: previewRedeem quotes
     * 1.05e18 - floor(1.05e18 * 0.02e18 / 1e18) = 1.029e18, so price = floor(1.029e18 * 1e8 / 1e8) = 1.029e18,
     * while a CONVERT_TO_ASSETS oracle over the same vault ignores the haircut and prices the nominal 1.05e18
     */
    function test_ERC4626_previewRedeemModePricesRealizableValue() public {
        vault.setRate(1.05e18);
        vault.setRedemptionHaircut(0.02e18);
        feed.setAnswer(1e8);
        ERC4626SharePriceOracle redeemOracle = new ERC4626SharePriceOracle(
            address(vault), ERC4626SharePriceOracle.ERC4626QueryMode.PREVIEW_REDEEM, address(feed), 0, uint32(T0), FEED_STALENESS, VAULT_SHARE_PRICE_STALENESS
        );
        assertEq(uint8(redeemOracle.ERC4626_QUERY_MODE()), uint8(ERC4626SharePriceOracle.ERC4626QueryMode.PREVIEW_REDEEM), "the query mode is stored immutably");
        (NAV_UNIT redeemPrice,) = redeemOracle.getPrice();
        assertEq(toUint256(redeemPrice), 1.029e18, "PREVIEW_REDEEM must price the haircut redemption value");
        (NAV_UNIT convertPrice,) = erc4626Oracle.getPrice();
        assertEq(toUint256(convertPrice), 1.05e18, "CONVERT_TO_ASSETS must price the nominal exchange rate, blind to the haircut");
    }

    /**
     * The two query modes agree exactly on a vault with no redemption haircut, so mode selection alone never
     * moves the price: both getPrice reports and both construction baselines match on the same vault state
     */
    function test_ERC4626_queryModesAgreeWithoutHaircut() public {
        vault.setRate(1.317e18);
        feed.setAnswer(0.98e8);
        ERC4626SharePriceOracle redeemOracle = new ERC4626SharePriceOracle(
            address(vault), ERC4626SharePriceOracle.ERC4626QueryMode.PREVIEW_REDEEM, address(feed), 0, uint32(T0), FEED_STALENESS, VAULT_SHARE_PRICE_STALENESS
        );
        ERC4626SharePriceOracle convertOracle = new ERC4626SharePriceOracle(
            address(vault),
            ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS,
            address(feed),
            0,
            uint32(T0),
            FEED_STALENESS,
            VAULT_SHARE_PRICE_STALENESS
        );
        (NAV_UNIT redeemPrice,) = redeemOracle.getPrice();
        (NAV_UNIT convertPrice,) = convertOracle.getPrice();
        assertEq(toUint256(redeemPrice), toUint256(convertPrice), "a haircut-free vault must price identically under both query modes");
        (uint160 redeemBaseline,) = redeemOracle.getOracleClockState();
        (uint160 convertBaseline,) = convertOracle.getOracleClockState();
        assertEq(uint256(redeemBaseline), uint256(convertBaseline), "both modes must checkpoint the same construction baseline on a haircut-free vault");
    }

    /**
     * The deviation clock in PREVIEW_REDEEM mode runs on the redemption value, so a haircut change alone is an
     * observable share-price update: the redeem clock advances to now while the nominal-rate clock holds its
     * attested checkpoint, and the committed checkpoint is the haircut redemption value
     */
    function test_ERC4626_previewRedeemModeClocksTheRedemptionValue() public {
        vault.setRate(1e18);
        feed.setAnswer(1e8);
        ERC4626SharePriceOracle redeemOracle = new ERC4626SharePriceOracle(
            address(vault), ERC4626SharePriceOracle.ERC4626QueryMode.PREVIEW_REDEEM, address(feed), 0, uint32(T0), FEED_STALENESS, VAULT_SHARE_PRICE_STALENESS
        );
        vm.warp(T0 + 1 days);
        // Keep the feed hop current so the oldest-hop report isolates the source clock under test
        feed.setUpdatedAt(T0 + 1 days);
        vault.setRedemptionHaircut(0.01e18);
        assertEq(redeemOracle.previewPoke(), T0 + 1 days, "a haircut change must read as a share-price deviation in PREVIEW_REDEEM mode");
        assertEq(erc4626Oracle.previewPoke(), T0, "the nominal exchange rate never moved, so CONVERT_TO_ASSETS holds its attested checkpoint");
        redeemOracle.poke();
        (uint160 checkpointedPrice,) = redeemOracle.getOracleClockState();
        assertEq(uint256(checkpointedPrice), 0.99e18, "the committed checkpoint must be the haircut redemption value");
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

    /// The report's timestamp is the OLDER hop: an older feed binds it, and with the share price at its attested
    /// construction checkpoint the clock binds once the feed is fresher
    function test_ERC4626_updatedAtIsTheOlderOfFeedAndShareClock() public {
        vault.setRate(1e18);
        feed.setAll(7, 2e8, T0 - 50, T0 - 10, 9);
        (NAV_UNIT price, uint256 updatedAt) = erc4626Oracle.getPrice();
        assertEq(toUint256(price), 2e18, "the composed price replaces the feed answer");
        assertEq(updatedAt, T0 - 10, "the older feed hop binds the report");

        // A fresher feed hands the clock to the attested share-price checkpoint
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 100);
        (, updatedAt) = erc4626Oracle.getPrice();
        assertEq(updatedAt, T0, "the attested share-price checkpoint binds once the feed is fresher");
    }

    /// A feed heartbeat alone never advances the clock: poke keeps the attested checkpoint until the share
    /// price itself is seen to move, which then stamps its observation time
    function test_ERC4626_feedHeartbeatAloneNeverAdvancesTheClock() public {
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 100);
        assertEq(erc4626Oracle.poke(), T0, "a feed heartbeat alone must never advance the clock");
        assertEq(erc4626Oracle.previewPoke(), T0, "previewPoke agrees while the share price is unmoved");

        // A share-price move is the genuine update: the clock stamps its observation time
        vault.setRate(1.01e18);
        assertEq(erc4626Oracle.poke(), T0 + 100, "a share-price deviation checkpoints the clock");

        // The mirror direction: a fresh deviation cannot outrun an older feed, the gate waits for the slower hop
        feed.setUpdatedAt(T0 + 50);
        vault.setRate(1.02e18);
        assertEq(erc4626Oracle.poke(), T0 + 50, "a share-price deviation with an older feed reports the feed's timestamp");
    }

    /**
     * The share-price hop's staleness gate: pricing fails shut once the checkpoint is older than the threshold,
     * however fresh the feed is, the exact boundary age still prices, and a fresh deviation re-opens pricing
     */
    function test_ERC4626_RevertIf_SharePriceCheckpointStale() public {
        // The exact boundary age still prices and binds the report's clock
        vm.warp(T0 + VAULT_SHARE_PRICE_STALENESS);
        feed.setUpdatedAt(block.timestamp);
        (, uint256 updatedAt) = erc4626Oracle.getPrice();
        assertEq(updatedAt, T0, "the boundary-age checkpoint still prices and binds the clock");

        // One second past the boundary fails shut on the share hop despite the fresh feed
        vm.warp(T0 + VAULT_SHARE_PRICE_STALENESS + 1);
        feed.setUpdatedAt(block.timestamp);
        vm.expectRevert(ClockedChainlinkPriceOracleBase.STALE_SOURCE_PRICE.selector);
        erc4626Oracle.getPrice();

        // A fresh share-price deviation reads as current and re-opens pricing
        vault.setRate(1.02e18);
        (, updatedAt) = erc4626Oracle.getPrice();
        assertEq(updatedAt, block.timestamp, "an observed deviation re-opens pricing at the current timestamp");
    }

    /// An unattested zero checkpoint holds pricing shut under the share-price staleness gate until the first deviation
    function test_ERC4626_unattestedCheckpointHoldsPricingShut() public {
        ERC4626SharePriceOracle unattested = new ERC4626SharePriceOracle(
            address(vault), ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS, address(feed), 0, 0, FEED_STALENESS, VAULT_SHARE_PRICE_STALENESS
        );
        vm.warp(T0 + VAULT_SHARE_PRICE_STALENESS + 1);
        feed.setUpdatedAt(block.timestamp);
        vm.expectRevert(ClockedChainlinkPriceOracleBase.STALE_SOURCE_PRICE.selector);
        unattested.getPrice();
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
        new ERC4626SharePriceOracle(
            address(0), ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS, address(feed), 0, uint32(T0), FEED_STALENESS, VAULT_SHARE_PRICE_STALENESS
        );
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ERC4626SharePriceOracle(
            address(vault), ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS, address(0), 0, uint32(T0), FEED_STALENESS, VAULT_SHARE_PRICE_STALENESS
        );
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

    /**
     * The report's clock is the older of the two hops: a stale machine AUM report gates a fresher feed and a
     * stale feed gates a fresher AUM report, so updatedAt never advances on one leg alone
     */
    function test_Makina_updatedAtIsTheOlderOfFeedAndAccounting() public {
        // A stale AUM report gates the fresher feed
        machine.setLastGlobalAccountingTime(T0 - 30);
        feed.setUpdatedAt(T0 - 10);
        (, uint256 updatedAt) = makinaOracle.getPrice();
        assertEq(updatedAt, T0 - 30, "a stale AUM report must gate the fresher feed");

        // A fresh AUM report hands the clock to the now-older feed leg
        machine.setLastGlobalAccountingTime(T0 - 5);
        (, updatedAt) = makinaOracle.getPrice();
        assertEq(updatedAt, T0 - 10, "a stale feed must gate the fresher AUM report");
    }

    /**
     * A feed heartbeat alone never advances the clock while the machine's AUM report stays stale, and poke and
     * previewPoke re-source through the same older-hop clock as getPrice
     */
    function test_Makina_feedHeartbeatAloneNeverAdvancesTheClock() public {
        machine.setLastGlobalAccountingTime(T0 - 30);
        feed.setUpdatedAt(T0 - 10);
        assertEq(makinaOracle.previewPoke(), T0 - 30, "previewPoke must report the older hop");

        // A fresh feed heartbeat leaves the clock pinned at the stale accounting time
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 100);
        assertEq(makinaOracle.poke(), T0 - 30, "a feed heartbeat alone must never advance the clock");

        // The clock only advances once the machine's next global accounting lands
        machine.setLastGlobalAccountingTime(T0 + 100);
        assertEq(makinaOracle.poke(), T0 + 100, "the clock advances once the AUM report lands");
    }

    /**
     * The machine-hop staleness gate: pricing fails shut once the last global accounting is older than the
     * accounting staleness threshold, however fresh the feed leg is, and the exact boundary age still prices
     */
    function test_Makina_RevertIf_AccountingOlderThanStalenessThreshold() public {
        // A fresh feed cannot carry a stale AUM report: only the machine hop is old here
        vm.warp(T0 + 10 days);
        feed.setUpdatedAt(block.timestamp);
        machine.setLastGlobalAccountingTime(block.timestamp - MAKINA_ACCOUNTING_STALENESS - 1);
        vm.expectRevert(MakinaSharePriceOracle.STALE_MAKINA_ACCOUNTING.selector);
        makinaOracle.getPrice();

        // The exact boundary age still prices and, as the older hop, binds the report's clock
        machine.setLastGlobalAccountingTime(block.timestamp - MAKINA_ACCOUNTING_STALENESS);
        (, uint256 updatedAt) = makinaOracle.getPrice();
        assertEq(updatedAt, block.timestamp - MAKINA_ACCOUNTING_STALENESS, "the boundary-age accounting hop must price and bind the clock");
    }

    /*----------------------------------------------------------------------
                        IdleCDOTranchePriceOracle
    ----------------------------------------------------------------------*/

    /**
     * The composed price is the live virtual price times the feed price, but updatedAt comes from the clock
     * Derivation: virtual price 1.01e6 at the 6-decimal underlying lifts by 1e12 to 1.01e18 and feed 1.00005e8:
     * price = floor(1.01e18 * 100005000 / 1e8) = 1.0100505e18 exact. The virtual price still sits at the
     * construction baseline, so previewPoke and therefore updatedAt report the attested T0-33 checkpoint, not the
     * feed's T0-10 (an UNATTESTED zero checkpoint fails the source staleness gate instead: pricing holds shut)
     */
    function test_IdleCDO_composesVirtualPriceWithFeed() public {
        IdleCDOTranchePriceOracle seeded = _deploySeededCDOOracle(address(aaTranche), uint32(T0 - 33));
        feed.setAll(7, 1.00005e8, T0 - 50, T0 - 10, 9);
        (NAV_UNIT price, uint256 updatedAt) = seeded.getPrice();
        assertEq(toUint256(price), 1.0100505e18, "composed price must be the virtual price times the feed price");
        assertEq(updatedAt, T0 - 33, "updatedAt is the clock's checkpoint, never the feed's timestamp");
        assertEq(seeded.decimals(), 18, "prices are reported at WAD precision");

        // The unattested oracle prices nothing: the zero checkpoint is stale by construction until a deviation
        vm.expectRevert(ClockedChainlinkPriceOracleBase.STALE_SOURCE_PRICE.selector);
        cdoOracle.getPrice();
    }

    /**
     * poke reports the composed report's timestamp, the oldest hop, so NEITHER leg alone opens the execution
     * gate: a feed heartbeat is bound by the unmoved clock, and a virtual price deviation is bound by an older feed
     */
    function test_IdleCDO_pokeReportsTheOldestHop() public {
        IdleCDOTranchePriceOracle seeded = _deploySeededCDOOracle(address(aaTranche), uint32(T0));

        // A fresh feed heartbeat is invisible to the clock: the tranche price has not moved
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 100);
        assertEq(seeded.poke(), T0, "a feed heartbeat alone must never open the execution gate");

        // A virtual price move checkpoints the clock at the wall-clock time it was observed, and the checkpoint persists
        cdo.setVirtualPrice(1.02e6);
        assertEq(seeded.poke(), T0 + 100, "a virtual price deviation checkpoints the clock");
        vm.warp(T0 + 200);
        feed.setUpdatedAt(T0 + 200);
        assertEq(seeded.poke(), T0 + 100, "the checkpoint persists until the next observed change");

        // A later feed heartbeat leaves getPrice's updatedAt pinned at the clock checkpoint
        feed.setUpdatedAt(T0 + 142);
        (, uint256 updatedAt) = seeded.getPrice();
        assertEq(updatedAt, T0 + 100, "updatedAt tracks the virtual price clock while the feed moves freely");

        // The mirror direction: a fresh deviation cannot outrun an older feed, the gate waits for the slower hop
        cdo.setVirtualPrice(1.03e6);
        assertEq(seeded.poke(), T0 + 142, "a virtual price deviation with an older feed reports the feed's timestamp");
    }

    /**
     * previewPoke reports what a poke would (the oldest hop) without committing a checkpoint: an uncommitted
     * deviation keeps floating with block.timestamp under a fresh feed until a poke commits it
     */
    function test_IdleCDO_previewPokeReportsWithoutCommitting() public {
        IdleCDOTranchePriceOracle seeded = _deploySeededCDOOracle(address(aaTranche), uint32(T0));
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 100);
        assertEq(seeded.previewPoke(), T0, "an unchanged virtual price reports the stored checkpoint");

        // An observed deviation under a fresh feed reports the current timestamp exactly as a poke would stamp it
        cdo.setVirtualPrice(1.02e6);
        assertEq(seeded.previewPoke(), T0 + 100, "a deviation previews the current timestamp");

        // Nothing was committed, so the same deviation re-previews at the new current timestamp
        vm.warp(T0 + 200);
        feed.setUpdatedAt(T0 + 200);
        assertEq(seeded.previewPoke(), T0 + 200, "an uncommitted deviation floats with block.timestamp");

        // The older feed hop binds the preview exactly as it binds getPrice
        feed.setUpdatedAt(T0 + 150);
        assertEq(seeded.previewPoke(), T0 + 150, "the older feed hop binds the preview");
        (, uint256 updatedAt) = seeded.getPrice();
        assertEq(updatedAt, T0 + 150, "previewPoke and getPrice report the same oldest-hop timestamp");

        // A poke commits the checkpoint, after which previewPoke reports the stored value under a fresh feed
        feed.setUpdatedAt(T0 + 200);
        assertEq(seeded.poke(), T0 + 200, "the poke commits the floating deviation");
        vm.warp(T0 + 300);
        feed.setUpdatedAt(T0 + 300);
        assertEq(seeded.previewPoke(), T0 + 200, "after the commit the stored checkpoint is reported");
    }

    /**
     * A configured deviation threshold mutes sub-threshold noise on the virtual price and checkpoints at the boundary
     * Derivation (threshold 1%): from the 1.01e6 baseline a move to 1.015e6 is ~0.495% (muted) and a move to
     * 1.0201e6 is exactly 1% (floor(1e18 * 10100 / 1010000) = 1e16 >= threshold, checkpointed)
     */
    function test_IdleCDO_deviationThresholdGatesTheClock() public {
        IdleCDOTranchePriceOracle gated =
            new IdleCDOTranchePriceOracle(address(cdo), address(aaTranche), address(feed), 0.01e18, uint32(T0), FEED_STALENESS, CDO_PRICE_STALENESS);
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 100);
        cdo.setVirtualPrice(1.015e6);
        assertEq(gated.poke(), T0, "a sub-threshold move never counts as an update");
        cdo.setVirtualPrice(1.0201e6);
        assertEq(gated.poke(), T0 + 100, "a move at the threshold checkpoints");
    }

    /// Construction wires the collateral identity against the CDO, pins the immutable clock configuration, and
    /// rejects null or non-member configuration through the static helper that runs before any constructor body
    function test_IdleCDO_constructionIdentityAndNullChecks() public {
        assertEq(cdoOracle.COLLATERAL_ASSET(), address(aaTranche), "the collateral asset is the configured CDO tranche");
        assertEq(cdoOracle.IDLE_CDO(), address(cdo), "the CDO is wired");
        assertEq(address(cdoOracle.ORACLE()), address(feed), "the feed is wired");
        assertEq(cdoOracle.MIN_DEVIATION_WAD(), 0, "the deviation threshold is a construction immutable");
        assertEq(cdoOracle.FEED_STALENESS_THRESHOLD_SECONDS(), FEED_STALENESS, "the feed hop's staleness threshold is a construction immutable");
        assertEq(cdoOracle.SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS(), CDO_PRICE_STALENESS, "the clock hop's staleness threshold is a construction immutable");
        // The clock baselines at the live virtual price lifted to WAD (1.01e6 at 6 underlying decimals is 1.01e18)
        (uint160 lastValue, uint32 lastUpdatedAt) = cdoOracle.getOracleClockState();
        assertEq(lastValue, 1.01e18, "the clock baselines at the construction-time virtual price in WAD");
        assertEq(lastUpdatedAt, 0, "a zero attested checkpoint stamps nothing");
        assertEq(cdoOracle.version(), 1, "version");
        assertEq(cdoOracle.description(), string.concat("AA_FalconXUSDC / ", feed.description()), "the description chains through the feed");
        // The constructor body's typed null check rejects a null CDO before any read can touch it
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new IdleCDOTranchePriceOracle(address(0), address(aaTranche), address(feed), 0, 0, FEED_STALENESS, CDO_PRICE_STALENESS);
        // The CDO's virtualPrice silently computes the BB price for any unknown address, so membership is checked
        vm.expectRevert(IdleCDOTranchePriceOracle.COLLATERAL_ASSET_MUST_BE_CDO_TRANCHE.selector);
        new IdleCDOTranchePriceOracle(address(cdo), makeAddr("NOT_A_TRANCHE"), address(feed), 0, 0, FEED_STALENESS, CDO_PRICE_STALENESS);
        // The clock's threshold bound is enforced at construction like every other immutable
        vm.expectRevert(OracleClockBase.INVALID_MIN_DEVIATION_WAD.selector);
        new IdleCDOTranchePriceOracle(address(cdo), address(aaTranche), address(feed), 1e18, 0, FEED_STALENESS, CDO_PRICE_STALENESS);
    }

    /// The oracle prices the BB (junior) tranche identically: virtualPrice works for either CDO tranche
    function test_IdleCDO_pricesTheBBTranche() public {
        MockERC20C bbTranche = new MockERC20C("BB_FalconXUSDC", "BB_FalconXUSDC", 18);
        cdo.setBBTranche(address(bbTranche));
        IdleCDOTranchePriceOracle bbOracle = _deploySeededCDOOracle(address(bbTranche), uint32(T0));
        assertEq(bbOracle.COLLATERAL_ASSET(), address(bbTranche), "the collateral asset is the BB tranche");
        (NAV_UNIT price,) = bbOracle.getPrice();
        assertEq(toUint256(price), 1.01e18, "the BB tranche's virtual price composes identically at the unit feed price");
        assertEq(bbOracle.description(), string.concat("BB_FalconXUSDC / ", feed.description()), "the description reads the BB chain");
    }

    /*----------------------------------------------------------------------
                        Per-hop staleness (immutable thresholds)
    ----------------------------------------------------------------------*/

    /// The feed hop fails shut at its own threshold on every single-hop adapter
    function test_RevertIf_FeedHopStale() public {
        vm.warp(T0 + FEED_STALENESS + 1); // the feed was stamped at T0 in setUp
        vm.expectRevert(ChainlinkPriceOracleBase.STALE_FEED_PRICE.selector);
        erc4626Oracle.getPrice();
        vm.expectRevert(ChainlinkPriceOracleBase.STALE_FEED_PRICE.selector);
        makinaOracle.getPrice();
    }

    /**
     * THE per-hop property this design exists for: the two hops of the CDO oracle cross their gates independently.
     * A stale feed fails shut even while the clock hop is fresh, and a stale clock fails shut even while the feed
     * is fresh — under a single shared threshold sized to the slow clock, the first case was unenforceable
     */
    function test_IdleCDO_hopsFailShutIndependently() public {
        IdleCDOTranchePriceOracle seeded = _deploySeededCDOOracle(address(aaTranche), uint32(T0));

        // Fresh clock, stale feed: past the feed's tight gate but well inside the clock's wide one
        vm.warp(T0 + FEED_STALENESS + 1);
        cdo.setVirtualPrice(1.02e6); // deviation: the clock hop previews as current
        vm.expectRevert(ChainlinkPriceOracleBase.STALE_FEED_PRICE.selector);
        seeded.getPrice();

        // Fresh feed, stale clock: the feed re-stamps but the checkpoint ages past the source gate
        feed.setUpdatedAt(block.timestamp);
        cdo.setVirtualPrice(1.01e6); // back to the checkpointed baseline: no deviation, the clock stays at T0
        vm.warp(T0 + CDO_PRICE_STALENESS + 1);
        feed.setUpdatedAt(block.timestamp);
        vm.expectRevert(ClockedChainlinkPriceOracleBase.STALE_SOURCE_PRICE.selector);
        seeded.getPrice();
    }

    /// Both thresholds are construction immutables and a zero threshold is rejected at construction, per hop
    function test_RevertIf_StalenessThresholdConstructedZero() public {
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        new ERC4626SharePriceOracle(
            address(vault), ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS, address(feed), 0, 0, 0, VAULT_SHARE_PRICE_STALENESS
        );
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        new ERC4626SharePriceOracle(address(vault), ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS, address(feed), 0, 0, FEED_STALENESS, 0);
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        new MakinaSharePriceOracle(address(machine), address(feed), 0, MAKINA_ACCOUNTING_STALENESS);
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        new MakinaSharePriceOracle(address(machine), address(feed), FEED_STALENESS, 0);
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        new IdleCDOTranchePriceOracle(address(cdo), address(aaTranche), address(feed), 0, 0, 0, CDO_PRICE_STALENESS);
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        new IdleCDOTranchePriceOracle(address(cdo), address(aaTranche), address(feed), 0, 0, FEED_STALENESS, 0);
    }

    /// A composition that floors to zero is REPORTED, not reverted: rejecting a zero price is the kernel's own
    /// guard (INVALID_PRICE at the price-cache fill), so the oracle stays an honest reporter of the composed value
    function test_ERC4626_composedZeroPriceReportsRatherThanReverts() public {
        vault.setRate(1);
        feed.setAnswer(1);
        (NAV_UNIT price,) = erc4626Oracle.getPrice();
        assertEq(toUint256(price), 0, "floor(1 x 1 / 1e8) composes to zero and is reported as such");
    }

    /// Every adapter in the family is a plain immutable contract: no initializer, no tick, no setter, no fallback
    function test_OracleFamily_hasNoAdminSurface() public {
        address[2] memory oracles = [address(erc4626Oracle), address(makinaOracle)];
        for (uint256 i = 0; i < oracles.length; i++) {
            (bool initOk,) = oracles[i].call(abi.encodeWithSignature("initialize(address,uint256,uint32)", address(this), uint256(0), uint32(0)));
            assertFalse(initOk, "the oracle is not a proxy and exposes no initializer");
            (bool tickOk,) = oracles[i].call(abi.encodeWithSignature("tick()"));
            assertFalse(tickOk, "the removed tick selector must not be callable");
            (bool setOk,) = oracles[i].call(abi.encodeWithSignature("setMinDeviationWAD(uint256)", uint256(0.01e18)));
            assertFalse(setOk, "no threshold setter exists");
        }
    }

    /**
     * The probe-amount decimals algebra holds on an inverted shape (6-decimal share over an 18-decimal base
     * asset): the probe is 10^(18 + 6 - 18) = 1e6 shares, whose conversion is the WAD share rate verbatim
     * Derivation: rate 1.02e18 and feed 1.00005e8: price = floor(1.02e18 * 100005000 / 1e8) = 1.020051e18
     */
    function test_ERC4626_invertedDecimalShapeComposesExactly() public {
        MockERC20C wideAsset = new MockERC20C("WIDE", "WIDE", 18);
        MockERC4626C narrowVault = new MockERC4626C(address(wideAsset), "Narrow Share", "nSHARE", 6);
        narrowVault.setRate(1.02e18);
        feed.setAnswer(1.00005e8);
        ERC4626SharePriceOracle narrow = new ERC4626SharePriceOracle(
            address(narrowVault),
            ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS,
            address(feed),
            0,
            uint32(T0),
            FEED_STALENESS,
            VAULT_SHARE_PRICE_STALENESS
        );
        (NAV_UNIT price,) = narrow.getPrice();
        assertEq(toUint256(price), 1.020051e18, "the inverted shape composes through the same probe algebra");
    }

    /// The Makina probe algebra holds on an inverted shape (6-decimal share over an 18-decimal accounting asset)
    function test_Makina_invertedDecimalShapeComposesExactly() public {
        MockERC20C narrowShare = new MockERC20C("nDUSD", "nDUSD", 6);
        MockERC20C wideAccounting = new MockERC20C("WUSD", "WUSD", 18);
        MockMakinaMachine narrowMachine = new MockMakinaMachine(address(narrowShare), address(wideAccounting), 1.02e18);
        feed.setAnswer(1.00005e8);
        MakinaSharePriceOracle narrow = new MakinaSharePriceOracle(address(narrowMachine), address(feed), FEED_STALENESS, MAKINA_ACCOUNTING_STALENESS);
        (NAV_UNIT price,) = narrow.getPrice();
        assertEq(toUint256(price), 1.020051e18, "the inverted shape composes through the same probe algebra");
    }

    /// A null machine cannot construct: the share-token resolution in the base constructor argument has no code
    /// to call, so deployment reverts (untyped, before any typed check can run)
    function test_RevertIf_Makina_nullMachineConstruction() public {
        vm.expectRevert();
        new MakinaSharePriceOracle(address(0), address(feed), FEED_STALENESS, MAKINA_ACCOUNTING_STALENESS);
    }

    /// poke and previewPoke dispatch through the overridden getPrice, so all three report the same oldest hop
    function test_Makina_pokeAgreesWithGetPrice() public {
        machine.setLastGlobalAccountingTime(T0 - 40);
        feed.setUpdatedAt(T0 - 10);
        (, uint256 updatedAt) = makinaOracle.getPrice();
        assertEq(updatedAt, T0 - 40, "getPrice reports the older accounting hop");
        assertEq(makinaOracle.poke(), updatedAt, "poke must agree with getPrice's report timestamp");
        assertEq(makinaOracle.previewPoke(), updatedAt, "previewPoke must agree with getPrice's report timestamp");
    }

    /// The oracle is a plain immutable contract: no initializer, no tick, no threshold setter, no fallback
    function test_IdleCDO_hasNoAdminSurface() public {
        (bool initOk,) = address(cdoOracle).call(abi.encodeWithSignature("initialize(address,uint256,uint32)", address(this), uint256(0), uint32(0)));
        assertFalse(initOk, "the oracle is not a proxy and exposes no initializer");
        (bool tickOk,) = address(cdoOracle).call(abi.encodeWithSignature("tick()"));
        assertFalse(tickOk, "the removed tick selector must not be callable");
        (bool setOk,) = address(cdoOracle).call(abi.encodeWithSignature("setMinDeviationWAD(uint256)", uint256(0.01e18)));
        assertFalse(setOk, "the removed setMinDeviationWAD selector must not be callable");
    }

    /// An attested construction checkpoint seeds the clock, and a future one fails shut
    function test_IdleCDO_constructionCheckpointSeedsTheClock() public {
        IdleCDOTranchePriceOracle seeded =
            new IdleCDOTranchePriceOracle(address(cdo), address(aaTranche), address(feed), 0, uint32(T0 - 100), FEED_STALENESS, CDO_PRICE_STALENESS);
        assertEq(seeded.poke(), T0 - 100, "the attested checkpoint is the clock's starting update");

        vm.expectRevert(OracleClockBase.INVALID_LAST_UPDATE_TIMESTAMP.selector);
        new IdleCDOTranchePriceOracle(address(cdo), address(aaTranche), address(feed), 0, uint32(T0 + 1), FEED_STALENESS, CDO_PRICE_STALENESS);
    }

    /**
     * The deviation blind spot fails shut: a virtual price republish the clock cannot observe holds the entry
     * point's execution gate shut until the next observable deviation. The removed tick was a
     * freshness-fabrication lever (it could stamp now with no genuine source update), so no caller can open the
     * gate by fiat, and reconfiguration is a redeploy plus a kernel oracle repoint
     */
    function test_IdleCDO_blindSpotFailsShutWithoutTick() public {
        IdleCDOTranchePriceOracle seeded = _deploySeededCDOOracle(address(aaTranche), uint32(T0));
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 100);
        assertEq(seeded.poke(), T0, "an unchanged virtual price must never stamp the clock");
        (bool tickOk,) = address(seeded).call(abi.encodeWithSignature("tick()"));
        assertFalse(tickOk, "no lever exists to stamp the blind spot");
        assertEq(seeded.poke(), T0, "the gate stays shut after the failed stamp attempt");

        // The next observable deviation opens the gate at its observation time
        cdo.setVirtualPrice(1.02e6);
        assertEq(seeded.poke(), T0 + 100, "the next observable deviation opens the gate");
    }
}
