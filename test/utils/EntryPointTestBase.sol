// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoDayEntryPoint } from "../../src/entrypoint/RoycoDayEntryPoint.sol";
import {
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE,
    ADMIN_PAUSER_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    JT_LP_ROLE,
    LT_LP_ROLE,
    PUBLIC_ROLE,
    ST_LP_ROLE
} from "../../src/factory/RolesConfiguration.sol";
import { IRoycoAuth } from "../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayEntryPoint } from "../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { AssetClaims, MarketState, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { MockRoycoFactory } from "../mocks/MockRoycoFactory.sol";
import { DayMarketTestBase } from "./DayMarketTestBase.sol";

/**
 * @title EntryPointTestBase
 * @notice The shared fixture for RoycoDayEntryPoint suites: deploys the entry point behind an ERC1967 proxy over a
 *         full Day market, wires the production-shaped role bindings, and provides request/execute/cancel helpers
 * @dev Suites call _deployMarket(...) with their chosen cell/params, then _deployEntryPoint(). Time helpers route
 *      through _warpAndRefreshFeed so delay warps never trip the ST/JT quoter's Chainlink staleness gate
 */
abstract contract EntryPointTestBase is DayMarketTestBase {
    using Math for uint256;

    // =============================
    // Constants
    // =============================

    /// @dev Default deposit delay (kept well under the 1-day oracle staleness threshold)
    uint24 internal constant DEFAULT_DEPOSIT_DELAY = 1 hours;

    /// @dev Default redemption delay (kept well under the 1-day oracle staleness threshold)
    uint24 internal constant DEFAULT_REDEMPTION_DELAY = 1 hours;

    /// @dev Default executor bonus (1%)
    uint64 internal constant DEFAULT_EXECUTOR_BONUS = 0.01e18;

    // =============================
    // Entry Point Handles
    // =============================

    /// @notice The entry point implementation
    RoycoDayEntryPoint internal entryPointImpl;

    /// @notice The entry point proxy
    IRoycoDayEntryPoint internal entryPoint;

    /// @notice The mock factory registering the fixture's tranches for the entry point's provenance validation
    MockRoycoFactory internal entryPointFactory;

    // =============================
    // Actors
    // =============================

    address internal USER_A;
    address internal USER_B;
    address internal EXECUTOR;
    address internal ENTRY_POINT_ADMIN;
    address internal FEE_COLLECTOR;

    // =============================
    // Deployment
    // =============================

    /**
     * @notice Deploys the entry point proxy over the already-deployed market and wires its production role bindings
     * @dev Must be called after _deployMarket. Registers all three tranches (ST, JT, LT) enabled with the default
     *      delays, grants the entry point the three LP roles, and creates the user/executor/admin actors
     */
    function _deployEntryPoint() internal virtual {
        // Register the market's tranches on the mock factory so the entry point's provenance validation passes
        entryPointFactory = new MockRoycoFactory(address(accessManager));
        entryPointFactory.setTrancheKernel(address(seniorTranche), address(kernel));
        entryPointFactory.setTrancheKernel(address(juniorTranche), address(kernel));
        entryPointFactory.setTrancheKernel(address(liquidityTranche), address(kernel));
        vm.label(address(entryPointFactory), "MockRoycoFactory");

        // Deploy the entry point behind an ERC1967 proxy, initialized with no tranche configs: the initial
        // configuration flows through the factory below, mirroring the production market deployment path
        entryPointImpl = new RoycoDayEntryPoint(address(entryPointFactory));
        entryPoint = IRoycoDayEntryPoint(
            address(
                new ERC1967Proxy(
                    address(entryPointImpl),
                    abi.encodeCall(RoycoDayEntryPoint.initialize, (new address[](0), new IRoycoDayEntryPoint.TrancheConfig[](0)))
                )
            )
        );
        vm.label(address(entryPoint), "EntryPoint");

        // Wire the production-shaped role bindings on the entry point itself
        address ep = address(entryPoint);
        accessManager.setTargetFunctionRole(
            ep,
            _sels(
                IRoycoDayEntryPoint.requestDeposit.selector,
                IRoycoDayEntryPoint.executeDeposit.selector,
                IRoycoDayEntryPoint.executeDeposits.selector,
                IRoycoDayEntryPoint.cancelDepositRequest.selector,
                IRoycoDayEntryPoint.cancelDepositRequests.selector
            ),
            PUBLIC_ROLE
        );
        accessManager.setTargetFunctionRole(
            ep,
            _sels(
                IRoycoDayEntryPoint.requestRedemption.selector,
                IRoycoDayEntryPoint.executeRedemption.selector,
                IRoycoDayEntryPoint.executeRedemptions.selector,
                IRoycoDayEntryPoint.cancelRedemptionRequest.selector,
                IRoycoDayEntryPoint.cancelRedemptionRequests.selector
            ),
            PUBLIC_ROLE
        );
        accessManager.setTargetFunctionRole(ep, _sels(IRoycoDayEntryPoint.pokeOracleClock.selector), PUBLIC_ROLE);
        accessManager.setTargetFunctionRole(ep, _sels(IRoycoDayEntryPoint.modifyTrancheConfigs.selector), ADMIN_ENTRY_POINT_ROLE);
        accessManager.setTargetFunctionRole(ep, _sels(IRoycoDayEntryPoint.collectProtocolFees.selector), ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE);
        accessManager.setTargetFunctionRole(ep, _sels(IRoycoAuth.pause.selector), ADMIN_PAUSER_ROLE);
        accessManager.setTargetFunctionRole(ep, _sels(IRoycoAuth.unpause.selector), ADMIN_UNPAUSER_ROLE);
        accessManager.setTargetFunctionRole(ep, _sels(UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE);

        // The entry point deposits, redeems, and receives escrowed shares
        accessManager.grantRole(ST_LP_ROLE, ep, 0);
        accessManager.grantRole(JT_LP_ROLE, ep, 0);
        accessManager.grantRole(LT_LP_ROLE, ep, 0);

        // Apply the initial tranche configs through the factory, as production market deployments do: the factory
        // holds ADMIN_ENTRY_POINT_ROLE (mirroring RoycoFactory.initialize) and forwards the admin-gated call
        accessManager.grantRole(ADMIN_ENTRY_POINT_ROLE, address(entryPointFactory), 0);
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        entryPointFactory.executeAsFactory(ep, abi.encodeCall(IRoycoDayEntryPoint.modifyTrancheConfigs, (tranches, configs)));

        // Entry point admin actors
        ENTRY_POINT_ADMIN = _generateActor("ENTRY_POINT_ADMIN", ADMIN_ENTRY_POINT_ROLE);
        FEE_COLLECTOR = _generateActor("FEE_COLLECTOR", ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE);

        // User actors, each holding all three LP roles so they can acquire shares and receive them under whitelisting
        USER_A = _generateEntryPointUser("USER_A");
        USER_B = _generateEntryPointUser("USER_B");
        EXECUTOR = _generateEntryPointUser("EXECUTOR");
    }

    /// @notice Builds the default 3-tranche (ST, JT, LT) config arrays: enabled, default delays, no oracle clock
    function _defaultTrancheConfigs() internal view returns (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) {
        tranches = new address[](3);
        tranches[0] = address(seniorTranche);
        tranches[1] = address(juniorTranche);
        tranches[2] = address(liquidityTranche);
        configs = new IRoycoDayEntryPoint.TrancheConfig[](3);
        for (uint256 i = 0; i < 3; ++i) {
            configs[i] = IRoycoDayEntryPoint.TrancheConfig({
                enabled: true, depositDelaySeconds: DEFAULT_DEPOSIT_DELAY, redemptionDelaySeconds: DEFAULT_REDEMPTION_DELAY, oracleClock: address(0)
            });
        }
    }

    /// @notice Creates a labeled, funded actor holding all three tranche LP roles
    function _generateEntryPointUser(string memory _name) internal returns (address user) {
        user = makeAddr(_name);
        vm.deal(user, 100 ether);
        accessManager.grantRole(ST_LP_ROLE, user, 0);
        accessManager.grantRole(JT_LP_ROLE, user, 0);
        accessManager.grantRole(LT_LP_ROLE, user, 0);
    }

    // =============================
    // PnL Injection (transaction-boundary faithful)
    // =============================

    /**
     * @notice Applies senior PnL and re-syncs, so quoter-cache state models the real transaction boundary
     * @dev The kernel's transient quoter cache clears at transaction end on-chain, but a forge test without isolation
     *      runs as ONE transaction: a cache warmed by an earlier kernel call in the same test would leak the pre-PnL
     *      rate into the entry point's execution-time forfeiture quotes (making forfeitures silently read as zero)
     *      Syncing after the PnL re-initializes the cache at the fresh rate, matching what any real cross-transaction
     *      sequence observes
     */
    function applySTPnL(int256 _bps) internal virtual override {
        super.applySTPnL(_bps);
        _sync();
    }

    /// @notice Applies junior PnL and re-syncs (see applySTPnL for the transaction-boundary rationale)
    function applyJTPnL(int256 _bps) internal virtual override {
        super.applyJTPnL(_bps);
        _sync();
    }

    /// @notice Applies liquidity tranche PnL and re-syncs (see applySTPnL for the transaction-boundary rationale)
    function applyLTPnL(int256 _bps) internal virtual override {
        super.applyLTPnL(_bps);
        _sync();
    }

    // =============================
    // Funding Helpers
    // =============================

    /// @notice Funds an account with a tranche's asset: shared vault shares for ST/JT, quote-backed BPT for LT
    /// @dev The BPT leg is minted against a value-matched quote-only pool leg so the pool's NAV-per-BPT stays ~1.0
    function _fundTrancheAssets(address _to, address _tranche, uint256 _amount) internal virtual {
        if (_tranche == address(liquidityTranche)) {
            uint256 quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
            uint256 quoteLeg = _amount.mulDiv(quoteUnit, WAD, Math.Rounding.Ceil) + quoteUnit;
            quoteToken.mint(address(this), quoteLeg);
            quoteToken.approve(address(balancerVault), quoteLeg);
            uint256[2] memory legs;
            legs[1 - stPoolTokenIndex] = quoteLeg;
            balancerVault.mintPoolTokensTo(address(bpt), _to, _amount, legs);
        } else {
            stJtVault.mintShares(_to, _amount);
        }
    }

    /**
     * @notice Acquires tranche shares for an account through the production deposit path
     * @dev Funds the account with the tranche's asset and deposits it directly on the tranche (the account holds
     *      the LP roles). ST deposits are liquidity-gated, so LT capacity is auto-topped-up first
     * @return shares The tranche shares minted to the account
     */
    function _acquireTrancheShares(address _user, address _tranche, uint256 _assets) internal virtual returns (uint256 shares) {
        if (_tranche == address(seniorTranche)) _ensureLiquidityCapacityForSTDeposit(_assets);
        _fundTrancheAssets(_user, _tranche, _assets);
        address asset = IRoycoVaultTranche(_tranche).asset();
        vm.startPrank(_user);
        IERC20Like(asset).approve(_tranche, _assets);
        shares = IRoycoVaultTranche(_tranche).deposit(toTrancheUnits(_assets), _user);
        vm.stopPrank();
    }

    // =============================
    // Request Helpers
    // =============================

    /// @notice Requests a deposit as _user, funding and approving the tranche's asset first
    function _requestDeposit(
        address _user,
        address _tranche,
        uint256 _assets,
        address _receiver,
        uint64 _executorBonusWAD
    )
        internal
        virtual
        returns (uint256 nonce, uint32 executableAt)
    {
        _fundTrancheAssets(_user, _tranche, _assets);
        address asset = IRoycoVaultTranche(_tranche).asset();
        vm.startPrank(_user);
        IERC20Like(asset).approve(address(entryPoint), _assets);
        (nonce, executableAt) = entryPoint.requestDeposit(_tranche, toTrancheUnits(_assets), _receiver, _executorBonusWAD);
        vm.stopPrank();
    }

    /// @notice Requests a deposit as _user with the default executor bonus, receiving to self
    function _requestDepositDefault(address _user, address _tranche, uint256 _assets) internal virtual returns (uint256 nonce, uint32 executableAt) {
        return _requestDeposit(_user, _tranche, _assets, _user, DEFAULT_EXECUTOR_BONUS);
    }

    /// @notice Requests a redemption as _user, acquiring and approving the tranche shares first
    function _requestRedemption(
        address _user,
        address _tranche,
        uint256 _shares,
        address _receiver,
        uint64 _executorBonusWAD
    )
        internal
        virtual
        returns (uint256 nonce, uint32 executableAt)
    {
        vm.startPrank(_user);
        IERC20Like(_tranche).approve(address(entryPoint), _shares);
        (nonce, executableAt) = entryPoint.requestRedemption(_tranche, _shares, _receiver, _executorBonusWAD);
        vm.stopPrank();
    }

    // =============================
    // Execution and Cancellation Helpers
    // =============================

    /// @notice Executes a deposit request as _executor for the specified amount
    function _executeDeposit(address _executor, address _user, uint256 _nonce, uint256 _assets) internal virtual returns (uint256 sharesMinted) {
        vm.prank(_executor);
        sharesMinted = entryPoint.executeDeposit(_user, _nonce, toTrancheUnits(_assets));
    }

    /// @notice Executes a deposit request as _executor for the maximum possible amount
    function _executeDepositMax(address _executor, address _user, uint256 _nonce) internal virtual returns (uint256 sharesMinted) {
        vm.prank(_executor);
        sharesMinted = entryPoint.executeDeposit(_user, _nonce, toTrancheUnits(type(uint256).max));
    }

    /// @notice Cancels a deposit request as _user, returning escrow to _receiver
    function _cancelDeposit(address _user, uint256 _nonce, address _receiver) internal virtual {
        vm.prank(_user);
        entryPoint.cancelDepositRequest(_nonce, _receiver);
    }

    /// @notice Executes a redemption request as _executor for the specified amount of shares
    function _executeRedemption(address _executor, address _user, uint256 _nonce, uint256 _shares) internal virtual returns (AssetClaims memory claims) {
        vm.prank(_executor);
        (claims,) = entryPoint.executeRedemption(_user, _nonce, _shares);
    }

    /// @notice Executes a redemption request as _executor for the maximum possible amount of shares
    function _executeRedemptionMax(address _executor, address _user, uint256 _nonce) internal virtual returns (AssetClaims memory claims) {
        vm.prank(_executor);
        (claims,) = entryPoint.executeRedemption(_user, _nonce, type(uint256).max);
    }

    /// @notice Executes a redemption request as _executor for the maximum possible amount of shares, returning the quote leg alongside the claims
    function _executeRedemptionMaxWithQuote(
        address _executor,
        address _user,
        uint256 _nonce
    )
        internal
        virtual
        returns (AssetClaims memory claims, uint256 quoteAssets)
    {
        vm.prank(_executor);
        (claims, quoteAssets) = entryPoint.executeRedemption(_user, _nonce, type(uint256).max);
    }

    /// @notice Cancels a redemption request as _user, returning escrow to _receiver
    function _cancelRedemption(address _user, uint256 _nonce, address _receiver) internal virtual {
        vm.prank(_user);
        entryPoint.cancelRedemptionRequest(_nonce, _receiver);
    }

    // =============================
    // Time and Market State Helpers
    // =============================

    /// @notice Warps past the default deposit delay, refreshing the price feed so the staleness gate never trips
    function _warpPastDepositDelay() internal virtual {
        _warpAndRefreshFeed(uint256(DEFAULT_DEPOSIT_DELAY) + 1);
    }

    /// @notice Warps past the default redemption delay, refreshing the price feed so the staleness gate never trips
    function _warpPastRedemptionDelay() internal virtual {
        _warpAndRefreshFeed(uint256(DEFAULT_REDEMPTION_DELAY) + 1);
    }

    /// @notice Enters FIXED_TERM via a covered senior drawdown (coverage utilization above WAD, below the liquidation threshold)
    function _enterFixedTerm() internal virtual {
        applySTPnL(-2000);
        SyncedAccountingState memory s = _sync();
        assertEq(uint8(s.marketState), uint8(MarketState.FIXED_TERM), "the covered drawdown must enter FIXED_TERM");
    }

    /// @notice Breaches the liquidation coverage utilization threshold via a deep senior drawdown (market stays/returns PERPETUAL)
    function _enterLiquidation() internal virtual {
        applySTPnL(-2100);
        SyncedAccountingState memory s = _sync();
        assertGe(s.coverageUtilizationWAD, s.coverageLiquidationUtilizationWAD, "the drawdown must breach the liquidation threshold");
    }

    // =============================
    // Assertion Helpers
    // =============================

    /// @notice Asserts every leg of an AssetClaims is zero
    function assertAssetClaimsZero(AssetClaims memory _claims, string memory _err) internal pure {
        assertEq(toUint256(_claims.stAssets) + toUint256(_claims.jtAssets) + toUint256(_claims.ltAssets) + _claims.stShares + toUint256(_claims.nav), 0, _err);
    }
}

/// @dev Minimal ERC20 approve surface so the fixture's helpers stay agnostic over MockERC20C / MockERC4626C / MockBPT / tranche shares
interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
