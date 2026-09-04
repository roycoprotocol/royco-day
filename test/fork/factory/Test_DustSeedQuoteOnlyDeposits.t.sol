// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { stdError } from "../../../lib/forge-std/src/StdError.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { DeploymentResult } from "../../../script/config/DeploymentTypes.sol";
import { DayMarketConfig } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketTypes.sol";
import { DeployMarketComponent } from "../../../script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol";
import { RoycoBlacklist } from "../../../src/auth/RoycoBlacklist.sol";
import { IRoycoLiquidityProviderTranche } from "../../../src/interfaces/IRoycoLiquidityProviderTranche.sol";
import { MarketDeploymentValidationLogic } from "../../../src/libraries/logic/factory/MarketDeploymentValidationLogic.sol";
import { RoycoDayTestBase } from "../../utils/RoycoDayTestBase.sol";

/**
 * @title Test_DustSeedQuoteOnlyDeposits
 * @notice Proves — through the REAL deployment pipeline, not a hand-rolled pool — that seeding the market's
 *         genesis pool liquidity with at least 1 wei of collateral fixes the quote-only LP deposit brick the
 *         live sr-reUSDe/USD1 market exhibits (see `Test_LiveSrReUsdePool_ZeroBalanceAdds`).
 *
 *         Mechanism: the template's `_seedPool` routes the genesis liquidity through the LP tranche's
 *         `depositMultiAsset(collateralAmount, quoteAmount, ...)`. A nonzero collateral leg mints senior shares
 *         into the pool's initialization, so the pool's senior-share balance is nonzero from genesis — and the
 *         Vault's per-token `balance + amountIn - 1` adjustment in `computeAddLiquidityUnbalanced` (the
 *         `0 + 0 - 1` underflow that bricks quote-only UNBALANCED adds) can never trigger. A quote-only seed
 *         (`collateralAmount: 0`, how the live market shipped) leaves the senior balance at zero and every
 *         subsequent quote-only LP deposit panics.
 *
 *         Both cases deploy the snUSD market config end to end through the pipeline (config registry -> factory
 *         -> template -> kernel genesis seed) varying ONLY `poolInitialization.collateralAmount`, then EXECUTE a
 *         real quote-only `depositMultiAsset` as the fixture's LP-role holder.
 *
 * @dev Requires env `MAINNET_RPC_URL` and (optionally) `FORK_BLOCK`, like `Test_DayMarketDeployment`.
 */
contract Test_DustSeedQuoteOnlyDeposits is RoycoDayTestBase {
    address internal constant BALANCER_V3_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;

    /// @dev Pool token registration order (a venue-initialization invariant mirrored from the kernel's venue logic)
    uint256 internal constant ST_SHARE_POOL_INDEX = 0;
    uint256 internal constant QUOTE_ASSET_POOL_INDEX = 1;

    /// @dev A quote-only follow-up deposit sized inside the pool's 5x unbalanced invariant-ratio bound
    ///      (the snUSD config seeds $1 of USDC) and above the Vault's 1e6 scaled18 minimum trade amount
    uint256 internal constant QUOTE_ONLY_DEPOSIT = 0.5e6; // $0.50 USDC

    function _forkConfiguration() internal view override returns (uint256 forkBlock, string memory forkRpcUrl) {
        // No skip: the suite FAILS (env not found) when MAINNET_RPC_URL is unset, instead of silently passing
        forkRpcUrl = vm.envString("MAINNET_RPC_URL");
        forkBlock = vm.envOr("FORK_BLOCK", uint256(25_400_000));
    }

    function setUp() public {
        // Fork mainnet + create wallets + stand up the pipeline components; each test deploys its own market
        _setUpRoyco();
    }

    /// @dev Deploys the snUSD market through the real pipeline with the given genesis collateral seed, funding
    ///      the deployer's seed legs exactly like the script flow, and returns the market surfaces under test
    function _deployMarketWithCollateralSeed(uint256 _collateralSeed)
        internal
        returns (IRoycoLiquidityProviderTranche lpt, address pool, address quoteAsset)
    {
        DayMarketConfig memory cfg = MARKET_REGISTRY.getDayMarketConfig("snUSD");
        cfg.poolInitialization.collateralAmount = _collateralSeed;

        // The deployment validation only admits a collateral seed leg on a market that requires no junior
        // coverage (`COLLATERAL_SEED_REQUIRES_ZERO_MIN_COVERAGE`, pinned by its own test below): the seed mints
        // senior exposure at genesis, before any junior buffer can exist. So the fixed variant must also ship
        // with zero minimum coverage — the fix is NOT reachable by config on a market that keeps its coverage
        // requirement (every currently-registered market config sets 3%-20%)
        if (_collateralSeed != 0) cfg.accountant.minCoverageWAD = 0;

        // The template pulls the genesis seed legs from the broadcasting deployer
        deal(cfg.pool.quoteAsset, DEPLOYER.addr, cfg.poolInitialization.quoteAmount);
        if (_collateralSeed != 0) deal(cfg.collateralAsset, DEPLOYER.addr, _collateralSeed);

        DeploymentResult memory result = _deployMarketThroughPipeline(cfg);
        _setDeployedMarket(result);

        lpt = IRoycoLiquidityProviderTranche(KERNEL.liquidityProviderTranche());
        pool = KERNEL.lptAsset();
        quoteAsset = KERNEL.quoteAsset();
    }

    /// @dev Executes a REAL quote-only multi-asset LP deposit as the fixture's LP-role holder
    function _executeQuoteOnlyDeposit(IRoycoLiquidityProviderTranche _lpt, address _quoteAsset) internal returns (uint256 shares) {
        deal(_quoteAsset, PROTOCOL_FEE_RECIPIENT_ADDRESS, QUOTE_ONLY_DEPOSIT); // holds LPT_LP_ROLE in the fixture role graph
        vm.startPrank(PROTOCOL_FEE_RECIPIENT_ADDRESS);
        IERC20(_quoteAsset).approve(address(_lpt), QUOTE_ONLY_DEPOSIT);
        (shares,) = _lpt.depositMultiAsset(0, QUOTE_ONLY_DEPOSIT, 0, PROTOCOL_FEE_RECIPIENT_ADDRESS);
        vm.stopPrank();
    }

    /// @notice Control — the live market's actual genesis shape: a quote-only seed leaves the pool with zero
    ///         senior shares, and a quote-only LP deposit through the real tranche flow panics in the Vault
    function test_QuoteOnlyGenesisSeed_BricksQuoteOnlyLptDeposits() public {
        (IRoycoLiquidityProviderTranche lpt, address pool, address quoteAsset) = _deployMarketWithCollateralSeed(0);

        // The genesis seed left the pool exactly like the live sr-reUSDe market: zero senior shares
        uint256[] memory balances = IVault(BALANCER_V3_VAULT).getCurrentLiveBalances(pool);
        assertEq(balances[ST_SHARE_POOL_INDEX], 0, "quote-only seed: pool holds zero senior shares");
        assertGt(balances[QUOTE_ASSET_POOL_INDEX], 0, "quote-only seed: pool holds the quote seed");

        // The quote-only deposit hits the Vault's `0 + 0 - 1` underflow through the kernel's UNBALANCED add
        deal(quoteAsset, PROTOCOL_FEE_RECIPIENT_ADDRESS, QUOTE_ONLY_DEPOSIT);
        vm.startPrank(PROTOCOL_FEE_RECIPIENT_ADDRESS);
        IERC20(quoteAsset).approve(address(lpt), QUOTE_ONLY_DEPOSIT);
        vm.expectRevert(stdError.arithmeticError);
        lpt.depositMultiAsset(0, QUOTE_ONLY_DEPOSIT, 0, PROTOCOL_FEE_RECIPIENT_ADDRESS);
        vm.stopPrank();
    }

    /// @notice THE FIX: 1 wei of collateral in the genesis seed mints a dust senior-share balance into the
    ///         pool's initialization, and quote-only LP deposits work from genesis onward
    function test_OneWeiCollateralGenesisSeed_UnbricksQuoteOnlyLptDeposits() public {
        (IRoycoLiquidityProviderTranche lpt, address pool, address quoteAsset) = _deployMarketWithCollateralSeed(1);

        // The 1 wei collateral leg landed in the pool as a nonzero senior-share balance at initialization
        uint256[] memory seededBalances = IVault(BALANCER_V3_VAULT).getCurrentLiveBalances(pool);
        assertGt(seededBalances[ST_SHARE_POOL_INDEX], 0, "1 wei collateral seed: pool holds senior shares from genesis");
        assertGt(seededBalances[QUOTE_ASSET_POOL_INDEX], 0, "1 wei collateral seed: pool holds the quote seed");

        // The previously-bricked operation now succeeds as a real executed deposit
        uint256 shares = _executeQuoteOnlyDeposit(lpt, quoteAsset);
        assertGt(shares, 0, "quote-only LP deposit mints tranche shares");

        // The add deepened the quote side only, leaving the protective senior balance untouched
        uint256[] memory balancesAfter = IVault(BALANCER_V3_VAULT).getCurrentLiveBalances(pool);
        assertEq(
            balancesAfter[ST_SHARE_POOL_INDEX],
            seededBalances[ST_SHARE_POOL_INDEX],
            "quote-only deposits never touch the senior balance"
        );
        assertGt(balancesAfter[QUOTE_ASSET_POOL_INDEX], seededBalances[QUOTE_ASSET_POOL_INDEX], "pool quote balance grew");

        // And it keeps working: the fix is durable across deposits, not a one-shot
        uint256 moreShares = _executeQuoteOnlyDeposit(lpt, quoteAsset);
        assertGt(moreShares, 0, "repeat quote-only LP deposit mints tranche shares");
    }

    /// @notice The boundary of the fix: the deployment flow REJECTS a collateral seed on a market that requires
    ///         junior coverage (as every currently-registered config does), because the seed would mint senior
    ///         exposure at genesis with no junior buffer — so a coverage-bearing market cannot reach the fix
    ///         through its genesis funding without also dropping its minimum coverage to zero
    function test_CollateralSeed_RejectedOnMarketsRequiringJuniorCoverage() public {
        DeployMarketComponent market = _marketComponent();

        DayMarketConfig memory cfg = MARKET_REGISTRY.getDayMarketConfig("snUSD");
        cfg.poolInitialization.collateralAmount = 1; // keep the config's standard nonzero minCoverageWAD
        cfg.roycoBlacklist = address(new RoycoBlacklist(BLACKLIST_OWNER, address(0), new address[](0)));
        deal(cfg.pool.quoteAsset, DEPLOYER.addr, cfg.poolInitialization.quoteAmount);
        deal(cfg.collateralAsset, DEPLOYER.addr, 1);

        bytes32 marketIdSeed = MARKET_REGISTRY.getMarketId(cfg.marketName, CHAIN.factory);
        vm.expectRevert(MarketDeploymentValidationLogic.COLLATERAL_SEED_REQUIRES_ZERO_MIN_COVERAGE.selector);
        market.deployMarket(cfg, marketIdSeed, DEPLOYER.privateKey);
    }
}
