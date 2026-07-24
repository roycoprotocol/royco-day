// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../utils/DayMarketTestBase.sol";
import { MarketParamsConfig } from "../utils/FixtureTypes.sol";
import { defaultParams, zeroLiquidityParams } from "../utils/MarketParams.sol";
import { RoycoTestMath } from "../utils/RoycoTestMath.sol";
import { cellA } from "../utils/TokenConfigs.sol";

/**
 * @title SeniorJuniorMarketDriver
 * @notice One fully deployed Day market wrapped in senior/junior-only op entrypoints that never touch the
 *         liquidity provider tranche, so two instances can be driven through byte-identical op sequences and compared
 * @dev Every op returns (succeeded, revertSelector) instead of reverting, so the caller can assert that both
 *      markets accept and reject the exact same operations for the exact same reasons
 */
contract SeniorJuniorMarketDriver is DayMarketTestBase {
    /// @dev Guards market setup against a second call
    bool internal marketInitialized;

    /**
     * @notice Everything the senior/junior engine commits or pays out, read from live state
     * @custom:field collateralNAV - The committed collateral NAV of the coinvested pool
     * @custom:field stEffectiveNAV - The committed senior effective NAV
     * @custom:field jtEffectiveNAV - The committed junior effective NAV
     * @custom:field jtImpermanentLoss - The committed junior impermanent-loss ledger
     * @custom:field marketState - The committed market state ordinal
     * @custom:field fixedTermEndTimestamp - The committed fixed-term end timestamp
     * @custom:field stSupply - The senior tranche share supply
     * @custom:field jtSupply - The junior tranche share supply
     * @custom:field stProviderTrancheShares - The senior LP's tranche share balance
     * @custom:field jtProviderTrancheShares - The junior LP's tranche share balance
     * @custom:field stProviderVaultShares - The senior LP's redeemed vault-share holdings outside the market
     * @custom:field jtProviderVaultShares - The junior LP's redeemed vault-share holdings outside the market
     */
    struct SeniorJuniorTrajectory {
        uint256 collateralNAV;
        uint256 stEffectiveNAV;
        uint256 jtEffectiveNAV;
        uint256 jtImpermanentLoss;
        uint8 marketState;
        uint256 fixedTermEndTimestamp;
        uint256 stSupply;
        uint256 jtSupply;
        uint256 stProviderTrancheShares;
        uint256 jtProviderTrancheShares;
        uint256 stProviderVaultShares;
        uint256 jtProviderVaultShares;
    }

    /**
     * @notice Every observable trace the liquidity overlay could leave on the market
     * @custom:field lptSupply - The liquidity provider tranche share supply
     * @custom:field lptOwnedSeniorTrancheShares - The kernel's idle liquidity premium senior share ledger
     * @custom:field kernelSeniorShareBalance - Senior tranche shares actually held by the kernel
     * @custom:field twLPTYieldShareAccrued - The accrued time-weighted liquidity yield share weight
     * @custom:field committedLPTRawNAV - The committed liquidity pool mark
     * @custom:field liquidityUtilizationWAD - The liquidity utilization recomputed from the committed marks
     */
    struct LiquidityOverlayTrace {
        uint256 lptSupply;
        uint256 lptOwnedSeniorTrancheShares;
        uint256 kernelSeniorShareBalance;
        uint256 twLPTYieldShareAccrued;
        uint256 committedLPTRawNAV;
        uint256 liquidityUtilizationWAD;
    }

    /**
     * @notice Deploys and seeds the market for the given parameterization, callable once
     * @dev Seeds 30,000 junior vault shares first (senior deposits are coverage-gated on junior NAV), then
     *      100,000 senior vault shares. With no minimum liquidity configured the market base seeds no pool
     *      depth, so the liquidity provider tranche starts unfunded and must remain so for the whole run
     * @param _params The market parameterization to deploy against the 18-decimal-vault, 6-decimal-quote token shape
     */
    function setUpMarket(MarketParamsConfig memory _params) external {
        require(!marketInitialized, "market already initialized");
        marketInitialized = true;
        require(_params.minLiquidityWAD == 0, "a zero minimum-liquidity market must carry no liquidity requirement");
        _deployMarket(cellA(), _params);
        _seedMarket(100_000e18, 30_000e18);
    }

    /// @notice The senior LP deposits vault shares through the production deposit path
    /// @dev Mints the vault shares fresh so both markets fund the op identically
    function seniorDeposit(uint256 _assets) external returns (bool succeeded, bytes4 revertSelector) {
        stJtVault.mintShares(ST_PROVIDER, _assets);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), _assets);
        try seniorTranche.deposit(toTrancheUnits(_assets), ST_PROVIDER) returns (uint256) {
            succeeded = true;
        } catch (bytes memory err) {
            revertSelector = bytes4(err);
        }
        vm.stopPrank();
    }

    /// @notice The senior LP redeems tranche shares through the production redemption path
    function seniorRedeem(uint256 _shares) external returns (bool succeeded, bytes4 revertSelector) {
        vm.prank(ST_PROVIDER);
        try seniorTranche.redeem(_shares, ST_PROVIDER, ST_PROVIDER) {
            succeeded = true;
        } catch (bytes memory err) {
            revertSelector = bytes4(err);
        }
    }

    /// @notice The junior LP deposits vault shares through the production deposit path
    function juniorDeposit(uint256 _assets) external returns (bool succeeded, bytes4 revertSelector) {
        stJtVault.mintShares(JT_PROVIDER, _assets);
        vm.startPrank(JT_PROVIDER);
        stJtVault.approve(address(juniorTranche), _assets);
        try juniorTranche.deposit(toTrancheUnits(_assets), JT_PROVIDER) returns (uint256) {
            succeeded = true;
        } catch (bytes memory err) {
            revertSelector = bytes4(err);
        }
        vm.stopPrank();
    }

    /// @notice The junior LP redeems tranche shares through the production redemption path
    function juniorRedeem(uint256 _shares) external returns (bool succeeded, bytes4 revertSelector) {
        vm.prank(JT_PROVIDER);
        try juniorTranche.redeem(_shares, JT_PROVIDER, JT_PROVIDER) {
            succeeded = true;
        } catch (bytes memory err) {
            revertSelector = bytes4(err);
        }
    }

    /// @notice Moves the shared senior/junior vault rate by a signed basis-point amount
    function moveSharedRate(int256 _bps) external {
        applySTPnL(_bps);
    }

    /// @notice Stamps the price feed fresh at the current timestamp so warped time does not trip staleness
    function refreshFeedFreshness() external {
        priceFeed.setUpdatedAt(block.timestamp);
    }

    /// @notice The keeper syncs the market's accounting
    function keeperSync() external returns (bool succeeded, bytes4 revertSelector) {
        vm.prank(SYNC_OPERATOR);
        try kernel.syncTrancheAccounting() {
            succeeded = true;
        } catch (bytes memory err) {
            revertSelector = bytes4(err);
        }
    }

    /// @notice Reads the full senior/junior trajectory from committed state and live balances
    function trajectory() external view returns (SeniorJuniorTrajectory memory t) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        t.collateralNAV = toUint256(a.lastCollateralNAV);
        t.stEffectiveNAV = toUint256(a.lastSTEffectiveNAV);
        t.jtEffectiveNAV = toUint256(a.lastJTEffectiveNAV);
        t.jtImpermanentLoss = toUint256(a.lastJTImpermanentLoss);
        t.marketState = uint8(a.lastMarketState);
        t.fixedTermEndTimestamp = uint256(a.fixedTermEndTimestamp);
        t.stSupply = seniorTranche.totalSupply();
        t.jtSupply = juniorTranche.totalSupply();
        t.stProviderTrancheShares = seniorTranche.balanceOf(ST_PROVIDER);
        t.jtProviderTrancheShares = juniorTranche.balanceOf(JT_PROVIDER);
        t.stProviderVaultShares = stJtVault.balanceOf(ST_PROVIDER);
        t.jtProviderVaultShares = stJtVault.balanceOf(JT_PROVIDER);
    }

    /// @notice Reads every trace the liquidity overlay could leave, all of which must stay zero in a zero minimum-liquidity market
    function overlayTrace() external view returns (LiquidityOverlayTrace memory o) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        IRoycoDayKernel.RoycoDayKernelState memory k = kernel.getState();
        o.lptSupply = liquidityProviderTranche.totalSupply();
        o.lptOwnedSeniorTrancheShares = k.lptOwnedSeniorTrancheShares;
        o.kernelSeniorShareBalance = seniorTranche.balanceOf(address(kernel));
        o.twLPTYieldShareAccrued = uint256(a.twLPTYieldShareAccruedWAD);
        o.committedLPTRawNAV = toUint256(a.lastLPTRawNAV);
        o.liquidityUtilizationWAD = RoycoTestMath.computeLiquidityUtilization(toUint256(a.lastSTEffectiveNAV), a.minLiquidityWAD, toUint256(a.lastLPTRawNAV));
    }
}

/**
 * @title Invariant_ReductionEquivalence
 * @notice Proves the liquidity overlay is a strict addition to the senior/junior engine: a market whose
 *         liquidity knobs are zeroed but whose liquidity model stays live and wired tracks the canonical
 *         zero minimum-liquidity market wei-for-wei through fuzzed senior/junior op sequences
 * @dev The two markets differ only in the liquidity overlay's configuration. The plain market is the
 *      canonical zero minimum-liquidity preset (no requirement, no premium cap, an all-zero liquidity
 *      curve). The disarmed market keeps the default parameterization's LIVE liquidity model, whose curve
 *      still answers a 10% yield share on every query, and silences it purely through the two liquidity
 *      knobs: a zero minimum liquidity (so the redemption and deposit gates have nothing to enforce) and a
 *      zero maximum liquidity yield share (so the model's answer is capped away before it can accrue).
 *      Neither market ever funds its liquidity provider tranche. If the overlay leaked into the engine anywhere,
 *      through the gate, the premium accrual, the pool mark, or the sync checkpoint, the step-by-step
 *      trajectories would diverge
 * @dev A default market that keeps its knobs armed does NOT reduce even with an unfunded liquidity provider tranche:
 *      a positive minimum liquidity against zero pool depth reads infinite utilization and blocks every
 *      senior deposit, and a positive yield-share cap accrues a premium off the live curve regardless of
 *      pool depth. The knobs, not the missing deposits, are what switch the overlay off, and this suite
 *      pins exactly that boundary
 */
contract Invariant_ReductionEquivalence is Test {
    /// @dev The number of fuzzed ops in one sequence
    uint256 internal constant SEQUENCE_LENGTH = 10;

    /// @dev The canonical zero minimum-liquidity market
    SeniorJuniorMarketDriver internal plainMarket;

    /// @dev The default-shaped market with only the two liquidity knobs zeroed and a live liquidity model
    SeniorJuniorMarketDriver internal disarmedMarket;

    function setUp() public {
        plainMarket = new SeniorJuniorMarketDriver();
        plainMarket.setUpMarket(zeroLiquidityParams());

        MarketParamsConfig memory p = defaultParams();
        // Zero the requirement so the liquidity gate has nothing to enforce against the unfunded tranche
        p.minLiquidityWAD = 0;
        // Zero the cap so the live model's 10% curve answer is capped away before it accrues any premium
        p.maxLPTYieldShareWAD = 0;
        disarmedMarket = new SeniorJuniorMarketDriver();
        disarmedMarket.setUpMarket(p);
    }

    /**
     * @notice One fuzzed sequence of senior/junior deposits, redemptions, shared-rate moves, and time passing,
     *         applied op-for-op to both markets: outcomes, revert reasons, and the full senior/junior
     *         trajectory must match at every step, and the liquidity overlay must leave zero trace in both
     * @param _opSeeds The per-step op selector seeds
     * @param _amountSeeds The per-step amount, rate-move, or duration seeds
     */
    function testFuzz_SeniorJuniorOpSequence_DisarmedLiquidityOverlay_TracksZeroMinimumLiquidityMarket(
        uint256[10] calldata _opSeeds,
        uint256[10] calldata _amountSeeds
    )
        public
    {
        for (uint256 i; i < SEQUENCE_LENGTH; ++i) {
            // Uniform over the six op kinds: two deposits, two redemptions, a rate move, and time passing
            uint256 op = bound(_opSeeds[i], 0, 5);
            bool okPlain;
            bytes4 selPlain;
            bool okDisarmed;
            bytes4 selDisarmed;

            if (op == 0) {
                // Uniform over 1e-6 to 1e6 whole vault shares, wide enough to press the coverage gate
                uint256 assets = bound(_amountSeeds[i], 1e12, 1e24);
                (okPlain, selPlain) = plainMarket.seniorDeposit(assets);
                (okDisarmed, selDisarmed) = disarmedMarket.seniorDeposit(assets);
            } else if (op == 1) {
                uint256 held = plainMarket.trajectory().stProviderTrancheShares;
                // Uniform over the holding, degraded to one share on an empty balance so the
                // insufficient-balance revert is asserted in both markets instead of skipped
                uint256 shares = bound(_amountSeeds[i], 1, held == 0 ? 1 : held);
                (okPlain, selPlain) = plainMarket.seniorRedeem(shares);
                (okDisarmed, selDisarmed) = disarmedMarket.seniorRedeem(shares);
            } else if (op == 2) {
                // Uniform over 1e-6 to 1e6 whole vault shares
                uint256 assets = bound(_amountSeeds[i], 1e12, 1e24);
                (okPlain, selPlain) = plainMarket.juniorDeposit(assets);
                (okDisarmed, selDisarmed) = disarmedMarket.juniorDeposit(assets);
            } else if (op == 3) {
                uint256 held = plainMarket.trajectory().jtProviderTrancheShares;
                // Uniform over the holding, degraded to one share on an empty balance so the
                // insufficient-balance revert is asserted in both markets instead of skipped
                uint256 shares = bound(_amountSeeds[i], 1, held == 0 ? 1 : held);
                (okPlain, selPlain) = plainMarket.juniorRedeem(shares);
                (okDisarmed, selDisarmed) = disarmedMarket.juniorRedeem(shares);
            } else if (op == 4) {
                // Uniform over minus three to plus three percent: bound(0, 600) - 300 spans [-300, 300] bps
                int256 bps = int256(bound(_amountSeeds[i], 0, 600)) - 300;
                plainMarket.moveSharedRate(bps);
                disarmedMarket.moveSharedRate(bps);
                (okPlain, selPlain) = plainMarket.keeperSync();
                (okDisarmed, selDisarmed) = disarmedMarket.keeperSync();
            } else {
                // Uniform over one second to thirty days, long enough for a fixed term to elapse
                uint256 duration = bound(_amountSeeds[i], 1, 30 days);
                vm.warp(block.timestamp + duration);
                plainMarket.refreshFeedFreshness();
                disarmedMarket.refreshFeedFreshness();
                (okPlain, selPlain) = plainMarket.keeperSync();
                (okDisarmed, selDisarmed) = disarmedMarket.keeperSync();
            }

            // The op must land identically in both markets, down to the revert reason
            assertEq(okPlain, okDisarmed, "op outcome diverged between the plain and the disarmed market");
            assertEq(selPlain, selDisarmed, "revert reason diverged between the plain and the disarmed market");

            // The liquidity gate must never be the thing that rejects a senior/junior op in either market
            assertTrue(selPlain != IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector, "the liquidity gate bound in the plain market");
            assertTrue(selDisarmed != IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector, "the liquidity gate bound in the disarmed market");

            _assertTrajectoriesMatch();
            _assertOverlayLeftNoTrace(plainMarket, "plain market");
            _assertOverlayLeftNoTrace(disarmedMarket, "disarmed market");
        }
    }

    /// @dev Asserts the two markets' senior/junior trajectories are equal field by field
    function _assertTrajectoriesMatch() internal view {
        SeniorJuniorMarketDriver.SeniorJuniorTrajectory memory a = plainMarket.trajectory();
        SeniorJuniorMarketDriver.SeniorJuniorTrajectory memory b = disarmedMarket.trajectory();
        assertEq(a.collateralNAV, b.collateralNAV, "collateral NAV diverged");
        assertEq(a.stEffectiveNAV, b.stEffectiveNAV, "senior effective NAV diverged");
        assertEq(a.jtEffectiveNAV, b.jtEffectiveNAV, "junior effective NAV diverged");
        assertEq(a.jtImpermanentLoss, b.jtImpermanentLoss, "junior impermanent-loss ledger diverged");
        assertEq(a.marketState, b.marketState, "market state diverged");
        assertEq(a.fixedTermEndTimestamp, b.fixedTermEndTimestamp, "fixed-term end diverged");
        assertEq(a.stSupply, b.stSupply, "senior share supply diverged (a liquidity premium mint would land here)");
        assertEq(a.jtSupply, b.jtSupply, "junior share supply diverged");
        assertEq(a.stProviderTrancheShares, b.stProviderTrancheShares, "senior LP tranche shares diverged");
        assertEq(a.jtProviderTrancheShares, b.jtProviderTrancheShares, "junior LP tranche shares diverged");
        assertEq(a.stProviderVaultShares, b.stProviderVaultShares, "senior LP redeemed holdings diverged");
        assertEq(a.jtProviderVaultShares, b.jtProviderVaultShares, "junior LP redeemed holdings diverged");
    }

    /// @dev Asserts every observable trace of the liquidity overlay is zero in the given market
    function _assertOverlayLeftNoTrace(SeniorJuniorMarketDriver _market, string memory _label) internal view {
        SeniorJuniorMarketDriver.LiquidityOverlayTrace memory o = _market.overlayTrace();
        assertEq(o.lptSupply, 0, string.concat(_label, ": the never-funded liquidity provider tranche minted shares"));
        assertEq(o.lptOwnedSeniorTrancheShares, 0, string.concat(_label, ": idle liquidity premium senior shares appeared in the kernel ledger"));
        assertEq(o.kernelSeniorShareBalance, 0, string.concat(_label, ": the kernel holds senior shares only a premium mint could give it"));
        assertEq(o.twLPTYieldShareAccrued, 0, string.concat(_label, ": liquidity yield-share weight accrued despite the zero cap"));
        assertEq(o.committedLPTRawNAV, 0, string.concat(_label, ": a pool mark was committed for the unfunded liquidity provider tranche"));
        assertEq(o.liquidityUtilizationWAD, 0, string.concat(_label, ": liquidity utilization must read zero with no requirement configured"));
    }
}
