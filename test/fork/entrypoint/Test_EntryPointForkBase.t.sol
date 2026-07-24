// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRouter } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IRouter.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { DeployScript } from "../../../script/Deploy.s.sol";
import { DeploymentResult } from "../../../script/config/DeploymentTypes.sol";
import { ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE, JT_LP_ROLE, LPT_LP_ROLE, ST_LP_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoLiquidityProviderTranche } from "../../../src/interfaces/IRoycoLiquidityProviderTranche.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { AggregatorV3Interface } from "../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { AssetClaims, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoDayTestBase } from "../../utils/RoycoDayTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/// @dev The minimal Permit2 surface the Balancer Router's token pulls require (no permit2 lib is vendored)
interface IPermit2ApproveLike {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/**
 * @title Test_EntryPointForkBase
 * @notice The RoycoDayEntryPoint's request/execute/cancel lifecycle against a REAL market deployed end-to-end
 *         through the production DeployScript on a mainnet fork: deposits with hand-derived share forfeiture,
 *         redemptions in every RedemptionMode with the exact value skim, executor bonuses paid in shares/claims,
 *         production expiry windows, and the self-liquidation bonus flowing through un-skimmed
 * @dev Extends RoycoDayTestBase (the test-free scaffold) rather than the kernel-suite chain, so this leaf carries
 *      ONLY the entry-point tests and never re-runs the kernel/venue suites. The pieces the kernel chain would have
 *      provided are ported: the base->NAV Chainlink feed mock (PnL injection + staleness-proof warps), tranche
 *      seeding, the LPT genesis deposit (the kernel's first multi-asset add initializes the real E-CLP pool), and
 *      external BPT acquisition through Balancer's canonical Router
 * @dev Every expected number is derived independently (RoycoTestMath over raw kernel/tranche reads), matching the
 *      concrete forfeiture-matrix suites. Each PnL move re-syncs the kernel so the transient price cache never
 *      leaks a pre-move rate into the entry point's forfeiture quotes (forge runs the test as one transaction)
 */
abstract contract Test_EntryPointForkBase is RoycoDayTestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONCRETE-MARKET HOOKS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The market config name the DeployScript deploys (e.g. "snUSD")
    function _marketName() internal pure virtual returns (string memory);

    /// @dev The base(asset)->NAV Chainlink-compatible feed backing the market's collateral oracle
    function _baseAssetToNavOracle() internal view virtual returns (address);

    /// @dev The pinned mainnet fork block
    function _forkBlockNumber() internal pure virtual returns (uint256);

    // ═══════════════════════════════════════════════════════════════════════════
    // MEMBERS
    // ═══════════════════════════════════════════════════════════════════════════

    IRoycoDayEntryPoint internal ENTRY_POINT;
    IRoycoVaultTranche internal LPT;
    address internal POOL;
    address internal COLLATERAL_ASSET;
    address internal QUOTE_ASSET;
    IVault internal VAULT;

    /// @dev The entry point actors: a requester holding all three LP roles, a role-less third-party executor, and a fee collector
    address internal EP_USER;
    address internal EP_RECEIVER;
    address internal EP_EXECUTOR;
    address internal EP_FEE_COLLECTOR;

    /// @dev The LPT seeder (LPT_LP_ROLE) whose genesis deposit initializes the real pool
    address internal EP_LPT_PROVIDER;

    uint256 internal QUOTE_UNIT;

    /// @dev Cached base->NAV feed answer, mocked once then moved by the PnL helpers; re-stamped fresh after warps
    int256 internal _mockedOracleAnswer;
    bool internal _oracleMocked;

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        // Config-driven fork: skip the whole suite when no RPC is configured (matching the kernel fork suites)
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, _forkBlockNumber());

        _setupWallets();
        DEPLOY_SCRIPT = new DeployScript();

        // Deploy the market end-to-end through the real script and capture the production entry point
        DeploymentResult memory result = DEPLOY_SCRIPT.deploy(
            DEPLOY_SCRIPT.getMarketConfig(_marketName()),
            OWNER_ADDRESS,
            PROTOCOL_FEE_RECIPIENT_ADDRESS,
            DEPLOY_SCRIPT.getChainConfig(block.chainid, false).scheduledOperationsExpirySeconds,
            _generateRoleAssignments(),
            DEPLOYER.privateKey
        );
        _setDeployedMarket(result);
        ENTRY_POINT = IRoycoDayEntryPoint(result.entryPoint);
        vm.label(address(ENTRY_POINT), "EntryPoint");

        COLLATERAL_ASSET = KERNEL.COLLATERAL_ASSET();
        QUOTE_ASSET = KERNEL.QUOTE_ASSET();
        QUOTE_UNIT = 10 ** IERC20Metadata(QUOTE_ASSET).decimals();
        LPT = IRoycoVaultTranche(KERNEL.LIQUIDITY_PROVIDER_TRANCHE());
        POOL = KERNEL.LPT_ASSET();
        VAULT = IVault(address(GyroECLPPoolFactory(DEPLOY_SCRIPT.getChainConfig(block.chainid, false).gyroECLPPoolFactory).getVault()));
        vm.label(address(LPT), "LPT");
        vm.label(POOL, "BalancerPool");

        // Providers (ST_/JT_ALICE... with LP roles) and the entry point actors
        _setupProviders();
        EP_USER = _generateProvider("EP_USER", ST_LP_ROLE).addr;
        EP_LPT_PROVIDER = _generateProvider("EP_LPT_PROVIDER", LPT_LP_ROLE).addr;
        EP_RECEIVER = _generateProvider("EP_RECEIVER", ST_LP_ROLE).addr;
        vm.startPrank(LP_ROLE_ADMIN_ADDRESS);
        ACCESS_MANAGER.grantRole(JT_LP_ROLE, EP_USER, 0);
        ACCESS_MANAGER.grantRole(LPT_LP_ROLE, EP_USER, 0);
        ACCESS_MANAGER.grantRole(JT_LP_ROLE, EP_RECEIVER, 0);
        ACCESS_MANAGER.grantRole(LPT_LP_ROLE, EP_RECEIVER, 0);
        vm.stopPrank();
        EP_EXECUTOR = makeAddr("EP_EXECUTOR");
        vm.deal(EP_EXECUTOR, 100 ether);
        EP_FEE_COLLECTOR = makeAddr("EP_FEE_COLLECTOR");

        // Fund with the real assets (plain `deal`, matching the kernel fork suites)
        deal(COLLATERAL_ASSET, ST_ALICE_ADDRESS, 1_000_000e18);
        deal(COLLATERAL_ASSET, JT_ALICE_ADDRESS, 1_000_000e18);
        deal(COLLATERAL_ASSET, EP_USER, 1_000_000e18);
        deal(COLLATERAL_ASSET, EP_LPT_PROVIDER, 1_000_000e18);
        deal(QUOTE_ASSET, EP_LPT_PROVIDER, 1_000_000 * QUOTE_UNIT);
        deal(QUOTE_ASSET, EP_USER, 1_000_000 * QUOTE_UNIT);

        // Seed the market: JT first (the coverage denominator), then ST, then the LPT genesis (the kernel's first
        // multi-asset add initializes the real E-CLP pool; minLiquidityWAD is 0 so ST never waits on LPT depth)
        _depositTranche(JT_ALICE_ADDRESS, JT, 30_000e18);
        _depositTranche(ST_ALICE_ADDRESS, ST, 50_000e18);
        _seedLPTGenesis(EP_LPT_PROVIDER, 2000e18);

        // Freeze the live feed value into the mock while it is fresh, so later warps can re-stamp it
        _pinOracleFresh();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE MOCK + WARP (ported from the ERC4626/Chainlink kernel base)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Moves the base->NAV feed by `sign * pctWAD` and re-syncs the kernel so the transient price cache
    ///      re-initializes at the fresh rate (forge runs the whole test as one transaction)
    function _movePnL(int256 _sign, uint256 _percentageWAD) internal {
        _moveOracle(_sign, _percentageWAD);
        _syncFork();
    }

    function _moveOracle(int256 _sign, uint256 _percentageWAD) internal {
        address oracle = _baseAssetToNavOracle();
        if (!_oracleMocked) {
            (, int256 answer,,,) = AggregatorV3Interface(oracle).latestRoundData();
            _mockedOracleAnswer = answer;
            _oracleMocked = true;
        }
        _mockedOracleAnswer += _sign * ((_mockedOracleAnswer * int256(_percentageWAD)) / int256(1e18));
        _applyOracleMock(oracle);
    }

    function _applyOracleMock(address _oracle) internal {
        vm.mockCall(
            _oracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), _mockedOracleAnswer, block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// @dev Freeze the live feed value into the mock (a 0% move) while it is still fresh
    function _pinOracleFresh() internal {
        _moveOracle(int256(1), 0);
    }

    /// @dev Warps forward keeping the mocked feed's updatedAt fresh on both sides, so staleness never trips
    function _warpForward(uint256 _secs) internal {
        _applyOracleMock(_baseAssetToNavOracle());
        vm.warp(block.timestamp + _secs);
        _applyOracleMock(_baseAssetToNavOracle());
    }

    /// @dev Syncs the market's accounting as the production sync-role holder
    function _syncFork() internal returns (SyncedAccountingState memory state) {
        vm.prank(SYNC_ROLE_ADDRESS);
        state = KERNEL.syncTrancheAccounting();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SEEDING + FUNDING HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deposits the collateral asset directly into an ST/JT tranche (the production path)
    function _depositTranche(address _lp, IRoycoVaultTranche _tranche, uint256 _assets) internal returns (uint256 shares) {
        vm.startPrank(_lp);
        IERC20(COLLATERAL_ASSET).approve(address(_tranche), _assets);
        shares = _tranche.deposit(toTrancheUnits(_assets), _lp);
        vm.stopPrank();
    }

    /// @dev Converts a collateral amount to the near-peg quote-asset amount of equal NAV (sizes value-matched legs)
    function _quoteAssetsMatching(uint256 _collateralAssets) internal view returns (uint256 quoteAssets) {
        return Math.mulDiv(toUint256(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(_collateralAssets))), QUOTE_UNIT, 1e18);
    }

    /// @dev The LPT genesis: the first multi-asset deposit initializes the real E-CLP pool through the kernel's add
    ///      callback (production genesis, no out-of-band Router bootstrap), with value-matched legs
    function _seedLPTGenesis(address _lp, uint256 _collateralAssets) internal returns (uint256 shares) {
        uint256 quoteAssets = _quoteAssetsMatching(_collateralAssets);
        vm.startPrank(_lp);
        IERC20(COLLATERAL_ASSET).approve(address(LPT), _collateralAssets);
        IERC20(QUOTE_ASSET).approve(address(LPT), quoteAssets);
        (shares,) = IRoycoLiquidityProviderTranche(address(LPT)).depositMultiAsset(_collateralAssets, quoteAssets, 0, _lp);
        vm.stopPrank();
    }

    /// @dev Acquires raw BPT for an actor through Balancer's canonical Router (an external unbalanced add): the ST
    ///      leg is borrowed live from ST_ALICE (no new senior exposure), the quote leg is dealt, and both are pulled
    ///      through the Permit2 two-step. Returns the BPT minted to the actor
    function _acquireBptExternally(address _actor, uint256 _stShares, uint256 _quoteAssets) internal returns (uint256 bptOut) {
        address router = 0xAE563E3f8219521950555F5962419C8919758Ea2; // Balancer canonical V3 Router (mainnet)
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // canonical Permit2

        // Fund: live ST shares from the seeder, dealt quote
        vm.prank(ST_ALICE_ADDRESS);
        IERC20(address(ST)).transfer(_actor, _stShares);
        deal(QUOTE_ASSET, _actor, IERC20(QUOTE_ASSET).balanceOf(_actor) + _quoteAssets);

        // Permit2 two-step allowances, then the unbalanced add ordered by pool registration index
        vm.startPrank(_actor);
        IERC20(address(ST)).approve(permit2, type(uint256).max);
        IERC20(QUOTE_ASSET).approve(permit2, type(uint256).max);
        IPermit2ApproveLike(permit2).approve(address(ST), router, type(uint160).max, type(uint48).max);
        IPermit2ApproveLike(permit2).approve(QUOTE_ASSET, router, type(uint160).max, type(uint48).max);
        IERC20[] memory tokens = VAULT.getPoolTokens(POOL);
        uint256[] memory exactAmountsIn = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            exactAmountsIn[i] = address(tokens[i]) == address(ST) ? _stShares : _quoteAssets;
        }
        bptOut = IRouter(router).addLiquidityUnbalanced(POOL, exactAmountsIn, 0, false, "");
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT LIFECYCLE HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Requests a deposit as `_user`, approving the tranche's asset to the entry point first
    function _epRequestDeposit(
        address _user,
        address _tranche,
        uint256 _assets,
        address _receiver,
        uint64 _bonusWAD
    )
        internal
        returns (uint256 nonce, uint32 executableAt, uint32 expiresAt)
    {
        address asset = IRoycoVaultTranche(_tranche).asset();
        vm.startPrank(_user);
        IERC20(asset).approve(address(ENTRY_POINT), _assets);
        (nonce, executableAt, expiresAt) = ENTRY_POINT.requestDeposit(_tranche, toTrancheUnits(_assets), _receiver, _bonusWAD);
        vm.stopPrank();
    }

    /// @dev Requests a redemption as `_user`, approving the tranche shares to the entry point first
    function _epRequestRedemption(
        address _user,
        address _tranche,
        uint256 _shares,
        address _receiver,
        uint64 _bonusWAD,
        IRoycoDayEntryPoint.RedemptionMode _mode
    )
        internal
        returns (uint256 nonce, uint32 executableAt, uint32 expiresAt)
    {
        vm.startPrank(_user);
        IERC20(_tranche).approve(address(ENTRY_POINT), _shares);
        (nonce, executableAt, expiresAt) = ENTRY_POINT.requestRedemption(_tranche, _shares, _receiver, _bonusWAD, _mode);
        vm.stopPrank();
    }

    /// @dev Warps past the tranche's production deposit delay (inside the execution window), keeping the feed fresh
    function _warpIntoDepositWindow(address _tranche) internal {
        _warpForward(uint256(ENTRY_POINT.getTrancheConfig(_tranche).baseConfig.depositDelaySeconds) + 1);
    }

    /// @dev Warps past the tranche's production redemption delay (inside the execution window), keeping the feed fresh
    function _warpIntoRedemptionWindow(address _tranche) internal {
        _warpForward(uint256(ENTRY_POINT.getTrancheConfig(_tranche).baseConfig.redemptionDelaySeconds) + 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INDEPENDENT DERIVATIONS (RoycoTestMath over raw state reads)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The deposit share reference: the kernel-priced deposit value over the post-sync mint basis at the
    ///      UNCLAMPED fair virtual-shares rate (LPT prices on raw NAV, others on effective NAV, supply includes the sync mints)
    function _derivedDepositReference(address _tranche, uint256 _assets) internal view returns (uint256 shares) {
        bool isLPT = (_tranche == address(LPT));
        NAV_UNIT depositValue = isLPT ? KERNEL.convertLPTAssetsToValue(toTrancheUnits(_assets)) : KERNEL.convertCollateralAssetsToValue(toTrancheUnits(_assets));
        (SyncedAccountingState memory state, AssetClaims memory claims, uint256 supply) =
            KERNEL.previewSyncTrancheAccountingFor(ENTRY_POINT.getTrancheConfig(_tranche).trancheType);
        NAV_UNIT navBasis = (isLPT ? state.lptRawNAV : claims.nav);
        return RoycoTestMath.convertToSharesUnclamped(toUint256(depositValue), toUint256(navBasis), supply);
    }

    /// @dev The redemption value reference: the shares' claim on the post-sync full tranche claims at the virtual-shares
    ///      rate (mirrors _redemptionValueReference via TrancheClaimsLogic._scaleAssetClaims, post-sync supply and claims)
    function _valueOf(address _tranche, uint256 _shares) internal view returns (uint256 value) {
        (, AssetClaims memory claims, uint256 supply) = KERNEL.previewSyncTrancheAccountingFor(ENTRY_POINT.getTrancheConfig(_tranche).trancheType);
        return RoycoTestMath.scaleClaimNav(_shares, toUint256(claims.nav), supply);
    }

    /// @dev The exact redemption skim: floor(shares * (vExec - vReq) / vExec), zero when value fell
    function _expectedSkim(uint256 _shares, uint256 _vReq, uint256 _vExec) internal pure returns (uint256 feeShares) {
        if (_vExec <= _vReq) return 0;
        return Math.mulDiv(_shares, _vExec - _vReq, _vExec, Math.Rounding.Floor);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPOSITS: the hand-derived share-forfeiture partition on real assets
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Runs a deposit-forfeiture cell on a real tranche: request, PnL move, execute, exact partition asserts
    function _runForkDepositCell(address _tranche, int256 _pnlSign, uint256 _pnlPctWAD, uint64 _bonusWAD) internal {
        uint256 amount = 1000e18;
        (uint256 nonce,,) = _epRequestDeposit(EP_USER, _tranche, amount, EP_RECEIVER, _bonusWAD);
        uint256 storedRef = ENTRY_POINT.getDepositRequest(EP_USER, nonce).equivalentSharesAtRequestTime;
        assertEq(storedRef, _derivedDepositReference(_tranche, amount), "the stored reference must equal the independently derived unclamped share count");

        if (_pnlPctWAD != 0) _movePnL(_pnlSign, _pnlPctWAD);
        _warpIntoDepositWindow(_tranche);

        uint256 sharesExec = IRoycoVaultTranche(_tranche).previewDeposit(toTrancheUnits(amount));
        address executor = (_bonusWAD == 0) ? EP_USER : EP_EXECUTOR;
        uint256 feeBefore = ENTRY_POINT.getProtocolFeeSharesPendingCollection(_tranche);
        vm.prank(executor);
        uint256 userShares = ENTRY_POINT.executeDeposit(EP_USER, nonce, toTrancheUnits(type(uint256).max));

        // The partition: user pinned to min(reference, execution mint), the excess forfeited, splits exact
        assertEq(userShares, Math.min(storedRef, sharesExec), "the user's mint must be pinned to min(reference, execution mint)");
        uint256 forfeited = ENTRY_POINT.getProtocolFeeSharesPendingCollection(_tranche) - feeBefore;
        assertEq(userShares + forfeited, sharesExec, "the minted shares must split exactly into the user's pin and the forfeited excess");

        // The bonus is a flooring share slice of the post-forfeiture mint; the receiver keeps the remainder
        uint256 expectedBonus = (_bonusWAD == 0) ? 0 : Math.mulDiv(userShares, _bonusWAD, 1e18, Math.Rounding.Floor);
        if (_bonusWAD != 0) assertEq(IERC20(_tranche).balanceOf(EP_EXECUTOR), expectedBonus, "the executor must receive the flooring share slice");
        assertEq(IERC20(_tranche).balanceOf(EP_RECEIVER), userShares - expectedBonus, "the receiver must keep the remainder of the mint");
        assertEq(
            IERC20(_tranche).balanceOf(address(ENTRY_POINT)),
            ENTRY_POINT.getProtocolFeeSharesPendingCollection(_tranche),
            "the entry point must hold exactly the pending protocol fee shares"
        );
    }

    /// @notice ST deposit + a real collateral gain: the capped senior underperforms, the excess mint is forfeited
    function test_forkDepositForfeiture_stGain_exactPartition() public {
        _runForkDepositCell(address(ST), 1, 0.05e18, 0);
        assertGt(ENTRY_POINT.getProtocolFeeSharesPendingCollection(address(ST)), 0, "the ST gain cell must forfeit a nonzero excess");
    }

    /// @notice The ST gain cell with a third-party executor: the bonus is a share slice of the post-forfeiture mint
    function test_forkDepositForfeiture_stGain_bonusPaidInShares() public {
        _runForkDepositCell(address(ST), 1, 0.05e18, 0.01e18);
        assertGt(IERC20(address(ST)).balanceOf(EP_EXECUTOR), 0, "the executor must be paid in freshly minted senior shares");
    }

    /// @notice JT deposit + a real collateral loss: the levered junior falls harder, the excess mint is forfeited
    ///         (the market's zero fixed-term duration keeps the loss PERPETUAL so the deposit stays executable)
    function test_forkDepositForfeiture_jtLoss_exactPartition() public {
        _runForkDepositCell(address(JT), -1, 0.05e18, 0);
        assertGt(ENTRY_POINT.getProtocolFeeSharesPendingCollection(address(JT)), 0, "the JT loss cell must forfeit a nonzero excess");
    }

    /// @notice A flat queue forfeits nothing on the real pricing path: the queued deposit mints the full amount
    function test_forkDeposit_flatQueue_forfeitsNothing() public {
        _runForkDepositCell(address(JT), 1, 0, 0);
        assertEq(ENTRY_POINT.getProtocolFeeSharesPendingCollection(address(JT)), 0, "a flat queue must forfeit nothing on the real market");
    }

    /// @notice An LPT deposit escrows REAL BPT (acquired through Balancer's canonical Router) and mints LPT shares
    ///         through the entry point with the same partition invariants
    function test_forkDepositForfeiture_lptBptEscrow_flatForfeitsNothing() public {
        // Acquire raw BPT externally: a small value-matched add against the seeded pool
        uint256 stShares = 100e18;
        uint256 bptAmount = _acquireBptExternally(EP_USER, stShares, _quoteAssetsMatching(stShares));
        assertGt(bptAmount, 0, "the external add must mint real BPT");

        (uint256 nonce,,) = _epRequestDeposit(EP_USER, address(LPT), bptAmount, EP_RECEIVER, 0);
        uint256 storedRef = ENTRY_POINT.getDepositRequest(EP_USER, nonce).equivalentSharesAtRequestTime;
        assertEq(storedRef, _derivedDepositReference(address(LPT), bptAmount), "the stored LPT reference must equal the derived unclamped count");

        _warpIntoDepositWindow(address(LPT));
        uint256 sharesExec = LPT.previewDeposit(toTrancheUnits(bptAmount));
        vm.prank(EP_USER);
        uint256 userShares = ENTRY_POINT.executeDeposit(EP_USER, nonce, toTrancheUnits(type(uint256).max));

        assertEq(userShares, Math.min(storedRef, sharesExec), "the LPT depositor must be pinned to min(reference, execution mint)");
        assertEq(ENTRY_POINT.getProtocolFeeSharesPendingCollection(address(LPT)), sharesExec - userShares, "the partition must hold on the real BPT deposit");
        assertEq(IERC20(address(LPT)).balanceOf(EP_RECEIVER), userShares, "the receiver must get the minted LPT shares");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REDEMPTIONS: the exact value skim + every RedemptionMode on real assets
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice ST INKIND redemption + a real collateral gain: the skim equals the exact value formula and the
    ///         claims settle in real snUSD vault shares
    function test_forkRedemption_stGain_exactSkim_inKind() public {
        uint256 shares = _depositTranche(EP_USER, ST, 1000e18);
        (uint256 nonce,,) = _epRequestRedemption(EP_USER, address(ST), shares, EP_RECEIVER, 0, IRoycoDayEntryPoint.RedemptionMode.INKIND);
        uint256 vReq = toUint256(ENTRY_POINT.getRedemptionRequest(EP_USER, nonce).valueAtRequestTime);
        assertEq(vReq, _valueOf(address(ST), shares), "the stored snapshot must equal the derived pro-rata claim");

        _movePnL(1, 0.05e18);
        _warpIntoRedemptionWindow(address(ST));

        uint256 vExec = _valueOf(address(ST), shares);
        uint256 expectedFee = _expectedSkim(shares, vReq, vExec);
        assertGt(expectedFee, 0, "sanity: the queued gain must skim");

        uint256 receiverBefore = IERC20(COLLATERAL_ASSET).balanceOf(EP_RECEIVER);
        vm.prank(EP_USER);
        (AssetClaims memory claims,) = ENTRY_POINT.executeRedemption(EP_USER, nonce, shares);

        assertEq(ENTRY_POINT.getProtocolFeeSharesPendingCollection(address(ST)), expectedFee, "the skim must equal the exact value-formula fee shares");
        assertEq(
            IERC20(COLLATERAL_ASSET).balanceOf(EP_RECEIVER) - receiverBefore,
            toUint256(claims.collateralAssets),
            "the real snUSD shares must land on the receiver"
        );
        assertApproxEqRel(toUint256(claims.nav), vReq, 0.001e18, "the receiver must be pinned to the request-time value");
    }

    /// @notice JT INKIND redemption + gain with a third-party bonus: exact skim, then the collateral leg splits
    function test_forkRedemption_jtGain_bonusSplitsClaims() public {
        uint256 shares = _depositTranche(EP_USER, JT, 1000e18);
        (uint256 nonce,,) = _epRequestRedemption(EP_USER, address(JT), shares, EP_RECEIVER, 0.01e18, IRoycoDayEntryPoint.RedemptionMode.INKIND);
        uint256 vReq = toUint256(ENTRY_POINT.getRedemptionRequest(EP_USER, nonce).valueAtRequestTime);

        _movePnL(1, 0.05e18);
        _warpIntoRedemptionWindow(address(JT));

        uint256 vExec = _valueOf(address(JT), shares);
        uint256 expectedFee = _expectedSkim(shares, vReq, vExec);
        assertGt(expectedFee, 0, "sanity: the levered gain must skim");

        vm.prank(EP_EXECUTOR);
        (AssetClaims memory userClaims,) = ENTRY_POINT.executeRedemption(EP_USER, nonce, shares);

        assertEq(ENTRY_POINT.getProtocolFeeSharesPendingCollection(address(JT)), expectedFee, "the skim must equal the exact value-formula fee shares");
        uint256 executorLeg = IERC20(COLLATERAL_ASSET).balanceOf(EP_EXECUTOR);
        uint256 receiverLeg = IERC20(COLLATERAL_ASSET).balanceOf(EP_RECEIVER);
        assertEq(receiverLeg, toUint256(userClaims.collateralAssets), "the receiver must get exactly the reported user claims");
        assertEq(executorLeg, Math.mulDiv(executorLeg + receiverLeg, 0.01e18, 1e18), "the executor's slice must equal the flooring scaled-claims fraction");
        assertEq(IERC20(COLLATERAL_ASSET).balanceOf(address(ENTRY_POINT)), 0, "no claim assets may remain in the entry point");
    }

    /// @notice LPT INKIND explicit redemption pays the real BPT leg to the receiver
    function test_forkRedemption_lptInKind_paysRealBpt() public {
        uint256 shares = _seedLPTGenesis(EP_USER, 200e18);
        (uint256 nonce,,) = _epRequestRedemption(EP_USER, address(LPT), shares, EP_RECEIVER, 0, IRoycoDayEntryPoint.RedemptionMode.INKIND);
        _warpIntoRedemptionWindow(address(LPT));

        uint256 receiverBptBefore = IERC20(POOL).balanceOf(EP_RECEIVER);
        vm.prank(EP_USER);
        (AssetClaims memory claims,) = ENTRY_POINT.executeRedemption(EP_USER, nonce, type(uint256).max);

        assertGt(toUint256(claims.lptAssets), 0, "the in-kind LPT redemption must pay a BPT leg");
        assertEq(IERC20(POOL).balanceOf(EP_RECEIVER) - receiverBptBefore, toUint256(claims.lptAssets), "the real BPT must land on the receiver");
    }

    /// @notice LPT MULTIASSET redemption exits through the real Balancer remove-liquidity path: the receiver is paid
    ///         a quote (USDC) leg, and a queued gain skims per the exact value formula first
    function test_forkRedemption_lptMultiAsset_paysQuoteAndSkimsExact() public {
        uint256 shares = _seedLPTGenesis(EP_USER, 200e18);
        uint256 redeemShares = shares / 2;
        (uint256 nonce,,) = _epRequestRedemption(EP_USER, address(LPT), redeemShares, EP_RECEIVER, 0, IRoycoDayEntryPoint.RedemptionMode.MULTIASSET);
        uint256 vReq = toUint256(ENTRY_POINT.getRedemptionRequest(EP_USER, nonce).valueAtRequestTime);

        _movePnL(1, 0.05e18);
        _warpIntoRedemptionWindow(address(LPT));

        uint256 vExec = _valueOf(address(LPT), redeemShares);
        uint256 expectedFee = _expectedSkim(redeemShares, vReq, vExec);

        uint256 receiverQuoteBefore = IERC20(QUOTE_ASSET).balanceOf(EP_RECEIVER);
        vm.prank(EP_USER);
        (, uint256 quoteAssets) = ENTRY_POINT.executeRedemption(EP_USER, nonce, redeemShares);

        assertGt(quoteAssets, 0, "MULTIASSET mode must pay a real USDC quote leg");
        assertEq(IERC20(QUOTE_ASSET).balanceOf(EP_RECEIVER) - receiverQuoteBefore, quoteAssets, "the quote leg must land on the receiver");
        assertEq(ENTRY_POINT.getProtocolFeeSharesPendingCollection(address(LPT)), expectedFee, "the multi-asset skim must equal the exact value-formula fee");
    }

    /// @notice OPTIMIZED mode stays in-kind when the in-kind bound serves the whole request (this market's zero
    ///         minimum liquidity leaves the in-kind bound unbinding)
    function test_forkRedemption_lptOptimized_staysInKindWithinBound() public {
        uint256 shares = _seedLPTGenesis(EP_USER, 200e18);
        (uint256 nonce,,) = _epRequestRedemption(EP_USER, address(LPT), shares, EP_RECEIVER, 0, IRoycoDayEntryPoint.RedemptionMode.OPTIMIZED);
        _warpIntoRedemptionWindow(address(LPT));

        vm.prank(EP_USER);
        (AssetClaims memory claims, uint256 quoteAssets) = ENTRY_POINT.executeRedemption(EP_USER, nonce, type(uint256).max);

        assertEq(quoteAssets, 0, "OPTIMIZED must stay in-kind when the in-kind bound serves the whole request");
        assertGt(toUint256(claims.lptAssets), 0, "the in-kind exit must pay the BPT leg");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EXPIRY under the production windows
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The production execution window: the request executes inside [executableAt, expiresAt), is terminal
    ///         at the boundary, and cancels whole afterwards
    function test_forkExpiry_productionWindow_terminalThenCancel() public {
        uint256 amount = 1000e18;
        (uint256 nonce, uint32 executableAt, uint32 expiresAt) = _epRequestDeposit(EP_USER, address(JT), amount, EP_RECEIVER, 0);
        IRoycoDayEntryPoint.TrancheConfig memory config = ENTRY_POINT.getTrancheConfig(address(JT)).baseConfig;
        assertEq(expiresAt, executableAt + config.depositExpirySeconds, "the production window must be one expiry-length past the executable timestamp");

        // Land exactly on the expiry boundary: the half-open window is already closed
        _warpForward(uint256(expiresAt) - block.timestamp);
        vm.prank(EP_USER);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.REQUEST_EXPIRED.selector, nonce));
        ENTRY_POINT.executeDeposit(EP_USER, nonce, toTrancheUnits(type(uint256).max));

        // Cancellation returns the whole escrow
        uint256 balBefore = IERC20(COLLATERAL_ASSET).balanceOf(EP_USER);
        vm.prank(EP_USER);
        ENTRY_POINT.cancelDepositRequest(nonce, EP_USER);
        assertEq(IERC20(COLLATERAL_ASSET).balanceOf(EP_USER) - balBefore, amount, "the expired request must return its full escrow on cancel");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SELF-LIQUIDATION BONUS + FEE COLLECTION on the real market
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice A deep real-feed drawdown breaches the liquidation threshold: the ST redemption through the entry
    ///         point carries the JT-funded bonus on top of the pro-rata claim, and the bonus is never skimmed
    function test_forkSelfLiqBonus_flowsThroughUnskimmed() public {
        uint256 shares = _depositTranche(EP_USER, ST, 1000e18);
        (uint256 nonce,,) = _epRequestRedemption(EP_USER, address(ST), shares, EP_RECEIVER, 0, IRoycoDayEntryPoint.RedemptionMode.INKIND);
        _warpIntoRedemptionWindow(address(ST));

        // A -35% collateral move wipes most of the junior buffer, breaching this market's ~1.0009 threshold
        _movePnL(-1, 0.35e18);
        SyncedAccountingState memory state = _syncFork();
        assertGe(state.coverageUtilizationWAD, state.coverageLiquidationUtilizationWAD, "setup: the drawdown must breach the liquidation threshold");

        uint256 proRataNAV = _valueOf(address(ST), shares);
        vm.prank(EP_USER);
        (AssetClaims memory claims,) = ENTRY_POINT.executeRedemption(EP_USER, nonce, type(uint256).max);

        assertEq(ENTRY_POINT.getProtocolFeeSharesPendingCollection(address(ST)), 0, "the self-liquidation bonus must never be skimmed as protocol fees");
        assertGt(toUint256(claims.nav), proRataNAV, "the redemption must carry the JT-funded self-liquidation bonus");
    }

    /// @notice Forfeited fee shares sweep to the collector on the real market through collectProtocolFees
    function test_forkProtocolFees_collectSweepsForfeitedShares() public {
        // Produce a real forfeiture (the ST gain cell)
        _runForkDepositCell(address(ST), 1, 0.05e18, 0);
        uint256 pending = ENTRY_POINT.getProtocolFeeSharesPendingCollection(address(ST));
        assertGt(pending, 0, "setup: the gain cell must accrue fee shares");

        // Grant the fee-claim role through the AccessManager admin and sweep
        vm.prank(OWNER_ADDRESS);
        ACCESS_MANAGER.grantRole(ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE, EP_FEE_COLLECTOR, 0);
        address[] memory tranches = new address[](1);
        tranches[0] = address(ST);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;
        vm.prank(EP_FEE_COLLECTOR);
        ENTRY_POINT.collectProtocolFees(tranches, amounts, EP_FEE_COLLECTOR);

        assertEq(IERC20(address(ST)).balanceOf(EP_FEE_COLLECTOR), pending, "the whole pending accrual must sweep to the collector");
        assertEq(ENTRY_POINT.getProtocolFeeSharesPendingCollection(address(ST)), 0, "the accrual must clear after the sweep");
    }
}
