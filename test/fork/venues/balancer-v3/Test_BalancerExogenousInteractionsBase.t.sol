// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRouter } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IRouter.sol";
import { IVault } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IVaultErrors } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";
import { IVaultMain } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultMain.sol";
import { SwapKind, VaultSwapParams } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

import { ST_LP_ROLE } from "../../../../src/factory/Roles.sol";
import { IRoycoDayAccountant } from "../../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoLiquidityProviderTranche } from "../../../../src/interfaces/IRoycoLiquidityProviderTranche.sol";
import { BalancerV3LiquidityVenue } from "../../../../src/kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { Test_BalancerLPGateReinvestBase } from "./Test_BalancerLPGateReinvestBase.t.sol";

/**
 * @dev Minimal exogenous session probe: opens its OWN Vault unlock session and relays one arbitrary call from
 *      inside it, bubbling any revert verbatim. Models the strongest position an exogenous party can hold
 *      against the venue (control of an open session) so tests can pin exactly what that position cannot reach.
 */
contract VaultSessionProbe {
    IVault private immutable _VAULT;

    error ONLY_VAULT();

    constructor(IVault _vault) {
        _VAULT = _vault;
    }

    /// @notice Opens an unlock session and relays `_data` to `_target` from inside it.
    function openSessionAndCall(address _target, bytes calldata _data) external returns (bytes memory) {
        return _VAULT.unlock(abi.encodeCall(this.relay, (_target, _data)));
    }

    /// @notice The unlock callback: relays the prepared call, bubbling failure byte for byte.
    function relay(address _target, bytes calldata _data) external returns (bytes memory ret) {
        require(msg.sender == address(_VAULT), ONLY_VAULT());
        bool ok;
        (ok, ret) = _target.call(_data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/**
 * @title Test_BalancerExogenousInteractionsBase
 * @notice The VENUE layer's exogenous-interaction module: fork tests for every pool surface an outside party
 *         can touch at real Gyro E-CLP math, and for Royco flows composed with that exogenous activity. Covers
 *         the full swap settlement matrix (exact-in and exact-out, both directions, dust to boundary size),
 *         the external liquidity matrix (proportional and single-sided joins and exits, the senior leg built
 *         through a REAL senior tranche deposit), Royco ops gated and floored against post-drift marks,
 *         donation inertness, the rate surface under exogenous supply moves, and the Vault session boundary.
 *         Chains linearly on the LP-gate/reinvest suite, so every oracle layer and asset leaf inherits it.
 *         Oracle-agnostic by the venue layering rule: prices and yields move only through the kernel-suite
 *         hooks, pool state only through real Vault and Router operations.
 * @dev REENTRANCY REACHABILITY NOTE: on this venue's asset shapes (plain ERC20/ERC4626 collateral shares and
 *      a hookless-token quote such as USDC) NO code path hands control to an exogenous party inside a Royco
 *      flow's unlock session. The pool is registered hookless (template-validated) and neither pool token has
 *      transfer callbacks, so mid-session injection into the kernel's unlock is unreachable here. The session
 *      guard is therefore pinned from the other side, at the unit level: an exogenous party that OWNS an open
 *      session cannot pull a Royco venue op into it (`whenVaultLocked`), cannot run Vault ops outside a
 *      session, and cannot exit its own session holding unsettled Vault value.
 */
abstract contract Test_BalancerExogenousInteractionsBase is Test_BalancerLPGateReinvestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // SHARED HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Executes an exact-out swap through the canonical Router as `_actor`.
    function _swapExactOut(
        address _actor,
        address _tokenIn,
        address _tokenOut,
        uint256 _exactAmountOut,
        uint256 _maxAmountIn
    )
        internal
        returns (uint256 amountIn)
    {
        vm.prank(_actor);
        amountIn = IRouter(_balancerV3Router())
            .swapSingleTokenExactOut(POOL, IERC20(_tokenIn), IERC20(_tokenOut), _exactAmountOut, _maxAmountIn, block.timestamp, false, "");
    }

    /// @notice Queries an exact-out swap through the Router's query mode under a reverted state snapshot.
    function _querySwapExactOut(address _tokenIn, address _tokenOut, uint256 _exactAmountOut) internal returns (bool ok, uint256 amountIn) {
        uint256 snapshotId = vm.snapshotState();
        vm.prank(address(0), address(0));
        (bool success, bytes memory ret) = _balancerV3Router()
            .call(abi.encodeCall(IRouter.querySwapSingleTokenExactOut, (POOL, IERC20(_tokenIn), IERC20(_tokenOut), _exactAmountOut, address(0), "")));
        vm.revertToState(snapshotId);
        ok = success;
        if (success) amountIn = abi.decode(ret, (uint256));
    }

    /**
     * @notice The smallest raw amount of `_token` a swap leg can carry against `_otherToken` without tripping
     *         the Vault's minimum-trade or zero-raw-output rejections. Restates the capacity prober's floor
     *         derivation: both legs must clear the scaled-18 minimum trade AND land a nonzero raw amount on
     *         the coarser-decimal side, so the floor is max(2 * minTrade, 10 * 10^(18 - coarseDecimals))
     *         scaled into the token's own decimals, plus one wei.
     */
    function _dustSwapAmount(address _token, address _otherToken) internal view returns (uint256) {
        uint256 dec = IERC20Metadata(_token).decimals();
        uint256 otherDec = IERC20Metadata(_otherToken).decimals();
        uint256 coarseDecimals = dec < otherDec ? dec : otherDec;
        uint256 floorScaled18 = Math.max(2 * VAULT.getMinimumTradeAmount(), 10 * 10 ** (18 - coarseDecimals));
        return Math.mulDiv(floorScaled18, 10 ** dec, WAD) + 1;
    }

    /**
     * @notice Independent mirror of the venue's TWO-STEP quantized LPT mark: `queryLPTAssetOracle` floors ONE
     *         WHOLE asset's price (oneWholeLPT * TVL / bptSupply), then the ledger conversion floors the
     *         kernel's owned amount at that already-floored price. Restated on plain mulDiv so a silent src
     *         re-quantization (a single-floor rewrite) diverges loudly.
     */
    function _twoStepQuantizedLPTMark() internal view returns (uint256) {
        uint256 oneWholeLPT = uint256(KERNEL.getState().oneWholeLPTAsset);
        uint256 pricePerWholeBPT = Math.mulDiv(oneWholeLPT, _poolTVL(), _bptSupply());
        return Math.mulDiv(toUint256(KERNEL.getState().totalLPTAssets), pricePerWholeBPT, oneWholeLPT);
    }

    /**
     * @notice Creates an external actor holding REAL senior shares acquired through the senior tranche's own
     *         deposit flow: LP role granted, collateral dealt, gates consulted. Nothing is minted or borrowed
     *         from insider actors, so the position is exactly what a permissioned third party builds on chain.
     */
    function _makeExternalSeniorDepositor(string memory _name, uint256 _collateralAssets) internal returns (address actor, uint256 stShares) {
        actor = _makeExternalLP(_name);
        vm.prank(LP_ROLE_ADMIN_ADDRESS);
        ACCESS_MANAGER.grantRole(ST_LP_ROLE, actor, 0);
        dealSTAsset(actor, _collateralAssets);
        assertLe(_collateralAssets, toUint256(ST.maxDeposit(actor)), "arrange: the external senior deposit must fit the advertised max");
        vm.startPrank(actor);
        IERC20(COLLATERAL_ASSET).approve(address(ST), _collateralAssets);
        stShares = ST.deposit(toTrancheUnits(_collateralAssets), actor);
        vm.stopPrank();
    }

    /// @dev Asserts every committed checkpoint mark and the kernel's owned-BPT ledger equal the captured baseline.
    function _assertCheckpointAndLedgerUntouched(IRoycoDayAccountant.RoycoDayAccountantState memory _a0, uint256 _lptOwned0, string memory _ctx) internal view {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(a.lastCollateralNAV, _a0.lastCollateralNAV, string.concat("committed collateral NAV touched: ", _ctx));
        assertEq(a.lastSTEffectiveNAV, _a0.lastSTEffectiveNAV, string.concat("committed ST effective NAV touched: ", _ctx));
        assertEq(a.lastJTEffectiveNAV, _a0.lastJTEffectiveNAV, string.concat("committed JT effective NAV touched: ", _ctx));
        assertEq(a.lastLPTRawNAV, _a0.lastLPTRawNAV, string.concat("committed LPT raw NAV touched: ", _ctx));
        assertEq(toUint256(KERNEL.getState().totalLPTAssets), _lptOwned0, string.concat("kernel owned-BPT ledger touched: ", _ctx));
    }

    /// @dev Non-dilution step assert for the external liquidity matrix. Tolerance derivation: Balancer rounds
    ///      amountsIn up and amountsOut down (in the pool's favor, documented in BasePoolMath), so the only
    ///      downward wobble on NAV per BPT is the Gyro invariant computation error each TVL read carries,
    ///      bounded by `calculateInvariantWithError`'s err term via `_navPerBPTInvariantErrorTolerance`.
    function _assertStepNonDilutive(uint256 _navPerBPTPre, uint256 _tolPre, string memory _ctx) internal view {
        assertGe(_navPerBPTWAD() + _tolPre, _navPerBPTPre, string.concat("NAV per BPT diluted by an exogenous op: ", _ctx));
    }

    /// @dev Pins one exact-in swap's settlement: executed output equals the query quote, the in-leg raw balance
    ///      moves by amountIn minus the measured aggregate-fee skim, the out-leg by exactly minus amountOut,
    ///      and the fee is charged on the input token only.
    function _pinExactInSettlement(address _tokenIn, address _tokenOut, uint256 _amountIn, string memory _ctx) internal {
        (bool ok, uint256 quoted) = _querySwapExactIn(_tokenIn, _tokenOut, _amountIn);
        assertTrue(ok, string.concat("arrange: the exact-in query must succeed: ", _ctx));

        uint256[] memory raw0 = _rawBalances();
        uint256 aggIn0 = VAULT.getAggregateSwapFeeAmount(POOL, IERC20(_tokenIn));
        uint256 aggOut0 = VAULT.getAggregateSwapFeeAmount(POOL, IERC20(_tokenOut));
        uint256 inIdx = _tokenIn == address(ST) ? _stPoolIndex() : _quotePoolIndex();

        address swapper = _makeExternalLP(string.concat("EXACT_IN_SWAPPER_", _ctx));
        if (_tokenIn == address(ST)) _fundExternalLP(swapper, _amountIn, 0);
        else _fundExternalLP(swapper, 0, _amountIn);
        // minOut set to the quote itself: any settlement below the quoted math reverts inside the Router
        uint256 amountOut = _swapExactIn(swapper, _tokenIn, _tokenOut, _amountIn, quoted);

        assertEq(amountOut, quoted, string.concat("the swap must settle at exactly the pool's quoted math: ", _ctx));
        uint256[] memory raw1 = _rawBalances();
        uint256 aggInDelta = VAULT.getAggregateSwapFeeAmount(POOL, IERC20(_tokenIn)) - aggIn0;
        assertEq(
            raw1[inIdx], raw0[inIdx] + _amountIn - aggInDelta, string.concat("the in-leg must move by amountIn minus the measured aggregate skim: ", _ctx)
        );
        assertEq(raw1[1 - inIdx], raw0[1 - inIdx] - amountOut, string.concat("the out-leg must move by exactly minus amountOut: ", _ctx));
        assertEq(
            VAULT.getAggregateSwapFeeAmount(POOL, IERC20(_tokenOut)), aggOut0, string.concat("the swap fee must be charged on the input token only: ", _ctx)
        );
    }

    /// @dev The exact-out mirror of `_pinExactInSettlement`: executed input equals the query quote (enforced by
    ///      passing the quote as maxAmountIn, so any overcharge reverts), the out-leg moves by exactly minus
    ///      the requested output, and the in-leg carries the input minus the measured aggregate skim.
    function _pinExactOutSettlement(address _tokenIn, address _tokenOut, uint256 _exactAmountOut, string memory _ctx) internal {
        (bool ok, uint256 quotedIn) = _querySwapExactOut(_tokenIn, _tokenOut, _exactAmountOut);
        assertTrue(ok, string.concat("arrange: the exact-out query must succeed: ", _ctx));

        uint256[] memory raw0 = _rawBalances();
        uint256 aggIn0 = VAULT.getAggregateSwapFeeAmount(POOL, IERC20(_tokenIn));
        uint256 inIdx = _tokenIn == address(ST) ? _stPoolIndex() : _quotePoolIndex();

        address swapper = _makeExternalLP(string.concat("EXACT_OUT_SWAPPER_", _ctx));
        if (_tokenIn == address(ST)) _fundExternalLP(swapper, quotedIn, 0);
        else _fundExternalLP(swapper, 0, quotedIn);
        uint256 amountIn = _swapExactOut(swapper, _tokenIn, _tokenOut, _exactAmountOut, quotedIn);

        assertEq(amountIn, quotedIn, string.concat("the exact-out swap must charge exactly the pool's quoted input: ", _ctx));
        uint256[] memory raw1 = _rawBalances();
        uint256 aggInDelta = VAULT.getAggregateSwapFeeAmount(POOL, IERC20(_tokenIn)) - aggIn0;
        assertEq(raw1[1 - inIdx], raw0[1 - inIdx] - _exactAmountOut, string.concat("the out-leg must move by exactly minus the requested output: ", _ctx));
        assertEq(
            raw1[inIdx], raw0[inIdx] + amountIn - aggInDelta, string.concat("the in-leg must move by amountIn minus the measured aggregate skim: ", _ctx)
        );
    }

    /// @notice The multi-asset deposit preview surfacing BOTH outputs (tranche shares and the venue's BPT out),
    ///         through the venue's query mode under a reverted state snapshot.
    function _previewDepositLPTMultiFull(uint256 _stAssets, uint256 _quoteAssets) internal returns (uint256 shares, uint256 lptAssetsOut) {
        uint256 snapshotId = vm.snapshotState();
        vm.prank(address(0), address(0));
        (bool ok, bytes memory ret) = address(LPT).call(abi.encodeCall(IRoycoLiquidityProviderTranche.previewDepositMultiAsset, (_stAssets, _quoteAssets)));
        vm.revertToState(snapshotId);
        if (!ok) _bubbleRevert(ret);
        (shares, lptAssetsOut) = abi.decode(ret, (uint256, uint256));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // A — EXOGENOUS SWAP MATRIX (exact-in and exact-out, both directions, dust to boundary)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice every exact-in swap settles at exactly the pool's quoted math with exact balance movement, for
     *         both directions at dust, mid (a quarter of the probed boundary capacity), and boundary size, and
     *         no size or direction touches the committed checkpoint, the kernel's owned-BPT ledger, or the
     *         live collateral-priced tranche NAVs.
     * @dev Sizes: dust is the derived minimum-trade floor, large is the probed range-boundary capacity itself.
     *      Each cell runs under a reverted state snapshot so every cell prices off the identical seeded state.
     */
    function test_ExogenousSwapExactIn_settlesAtQuotedMath_allSizesBothDirections() public {
        _seedForSwaps();
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        uint256 lptOwned0 = toUint256(KERNEL.getState().totalLPTAssets);
        uint256 stLive0 = toUint256(ST.totalAssets().nav);
        uint256 jtLive0 = toUint256(JT.totalAssets().nav);

        for (uint256 dir = 0; dir < 2; ++dir) {
            address tokenIn = dir == 0 ? testConfig.quoteAsset : address(ST);
            address tokenOut = dir == 0 ? address(ST) : testConfig.quoteAsset;
            uint256 capacity = _maxSwapInBeforeRangeRevert(tokenIn);
            assertGt(capacity, 0, "arrange: the pool must have capacity in the probed direction");
            uint256[3] memory sizes = [_dustSwapAmount(tokenIn, tokenOut), capacity / 4, capacity];
            for (uint256 i = 0; i < 3; ++i) {
                uint256 snapshotId = vm.snapshotState();
                string memory ctx = string.concat(vm.toString(dir), "_", vm.toString(i));
                _pinExactInSettlement(tokenIn, tokenOut, sizes[i], ctx);
                _assertCheckpointAndLedgerUntouched(a0, lptOwned0, ctx);
                assertEq(toUint256(ST.totalAssets().nav), stLive0, string.concat("live senior NAV moved on an exogenous swap: ", ctx));
                assertEq(toUint256(JT.totalAssets().nav), jtLive0, string.concat("live junior NAV moved on an exogenous swap: ", ctx));
                vm.revertToState(snapshotId);
            }
        }
    }

    /**
     * @notice the exact-out mirror: every exact-out swap charges exactly the quoted input and pays exactly the
     *         requested output at dust, mid, and near-boundary size in both directions, with the checkpoint,
     *         ledger, and live tranche NAVs untouched.
     * @dev Large size derivation: the exact-out boundary is the same E-CLP range wall the exact-in prober
     *      found, so 90% of the boundary trade's own output is strictly inside it (the exact-in/exact-out fee
     *      asymmetry shifts the wall by about the 1bp fee, far under the 10% margin).
     */
    function test_ExogenousSwapExactOut_settlesAtQuotedMath_allSizesBothDirections() public {
        _seedForSwaps();
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        uint256 lptOwned0 = toUint256(KERNEL.getState().totalLPTAssets);

        for (uint256 dir = 0; dir < 2; ++dir) {
            address tokenIn = dir == 0 ? testConfig.quoteAsset : address(ST);
            address tokenOut = dir == 0 ? address(ST) : testConfig.quoteAsset;
            uint256 capacity = _maxSwapInBeforeRangeRevert(tokenIn);
            assertGt(capacity, 0, "arrange: the pool must have capacity in the probed direction");
            (bool ok, uint256 outAtCapacity) = _querySwapExactIn(tokenIn, tokenOut, capacity);
            assertTrue(ok, "arrange: the boundary-capacity query must succeed");
            uint256[3] memory outSizes = [_dustSwapAmount(tokenOut, tokenIn), outAtCapacity / 4, Math.mulDiv(outAtCapacity, 9, 10)];
            for (uint256 i = 0; i < 3; ++i) {
                uint256 snapshotId = vm.snapshotState();
                string memory ctx = string.concat(vm.toString(dir), "_", vm.toString(i));
                _pinExactOutSettlement(tokenIn, tokenOut, outSizes[i], ctx);
                _assertCheckpointAndLedgerUntouched(a0, lptOwned0, ctx);
                vm.revertToState(snapshotId);
            }
        }
    }

    /**
     * @notice an exogenous swap moves the committed LPT mark ONLY through the next sync, which commits the
     *         fee-grown mark at the venue's TWO-STEP quantized valuation (one whole asset's price floors
     *         first, the ledger amount floors at that price), in the upward direction the fee-driven invariant
     *         growth implies, while every other committed mark is byte-identical.
     * @dev Direction derivation: a swap changes the invariant only by the pool-retained fee (invariant
     *      monotonicity of the E-CLP under fee-charging trades), so TVL and hence the floored per-asset price
     *      weakly rise and the committed mark can never fall from exogenous swaps.
     */
    function test_ExogenousSwap_syncCommitsTwoStepQuantizedMark_onlyLPTMarkMoves() public {
        _seedForSwaps();
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        uint256 lptOwned0 = toUint256(KERNEL.getState().totalLPTAssets);

        (address swapper, uint256 amountIn) = _armSwapper(testConfig.quoteAsset, 0.5e18);
        _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, 0);

        // Ledger-priced, not balance-priced: nothing commits until a sync
        _assertCheckpointAndLedgerUntouched(a0, lptOwned0, "pre-sync");

        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a1 = ACCOUNTANT.getState();
        assertEq(toUint256(a1.lastLPTRawNAV), _twoStepQuantizedLPTMark(), "the committed mark must equal the two-step quantized mirror");
        assertGe(toUint256(a1.lastLPTRawNAV), toUint256(a0.lastLPTRawNAV), "the fee-grown mark can only move up");
        assertEq(a1.lastCollateralNAV, a0.lastCollateralNAV, "the collateral mark must be untouched by the swap's sync");
        assertEq(a1.lastSTEffectiveNAV, a0.lastSTEffectiveNAV, "the senior mark must be untouched by the swap's sync");
        assertEq(a1.lastJTEffectiveNAV, a0.lastJTEffectiveNAV, "the junior mark must be untouched by the swap's sync");
        _assertCommittedConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // B — EXOGENOUS LIQUIDITY MATRIX (external LP, all join and exit shapes)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice an external SINGLE-SIDED QUOTE join obeys the derived leak law on the quote axis
     *         ((1 - wQuote) * V * (f + (1 - pQuote)) with pQuote the quote leg's internal price), the minted
     *         BPT lands with the actor, and the kernel's ledger and the committed checkpoint stay untouched.
     */
    function test_ExogenousJoinSingleSidedQuote_leakMatchesLaw_kernelLedgerUntouched() public {
        _seedForSwaps();
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        uint256 lptOwned0 = toUint256(KERNEL.getState().totalLPTAssets);
        uint256 quoteShare0 = WAD - _stValueShareWAD();
        uint256 quoteSpot0 = Math.mulDiv(WAD, WAD, _spotSTinQuoteWAD());
        uint256 navPerBPT0 = _navPerBPTWAD();
        uint256 invTol = _navPerBPTInvariantErrorTolerance(navPerBPT0);

        address actor = _makeExternalLP("EXOGENOUS_QUOTE_JOINER");
        uint256 quoteAssets = _rawBalances()[_quotePoolIndex()] / 20;
        _fundExternalLP(actor, 0, quoteAssets);
        uint256 valueIn = _quoteToNAV(quoteAssets);

        uint256 bptOut = _externalAddUnbalanced(actor, 0, quoteAssets, 0);

        assertEq(IERC20(POOL).balanceOf(actor), bptOut, "the minted BPT must land with the external actor");
        uint256 mintedValue = Math.mulDiv(bptOut, _mtmPerBPTWAD(), WAD);
        int256 leak = int256(valueIn) - int256(mintedValue);
        (int256 expectedLeak, uint256 slack) = _expectedSingleSidedAddLeak(valueIn, quoteShare0, quoteSpot0, Math.mulDiv(WAD, WAD, _spotSTinQuoteWAD()));
        assertApproxEqAbs(leak, expectedLeak, slack, "the quote-side join leak must match (1-w)*V*(f + (1-q))");
        _assertStepNonDilutive(navPerBPT0, invTol, "single-sided quote join");
        _assertCheckpointAndLedgerUntouched(a0, lptOwned0, "single-sided quote join");
    }

    /**
     * @notice an external SINGLE-SIDED SENIOR join built from REAL senior shares (acquired through the senior
     *         tranche's own gated deposit flow, never minted or borrowed) mints BPT to the actor only, cannot
     *         dilute NAV per BPT, and leaves the kernel's owned-BPT ledger and the committed checkpoint alone.
     */
    function test_ExogenousJoinSingleSidedSenior_viaRealSTDeposit_navPerBPTNonDilutive() public {
        _seedForSwaps();
        // Sizing only: a deposit worth ~5% of the pool's senior leg at the near-peg rate
        uint256 targetValue = _liveBalances()[_stPoolIndex()] / 20;
        uint256 assets = toUint256(KERNEL.convertValueToCollateralAssets(toNAVUnits(targetValue)));
        (address actor, uint256 stShares) = _makeExternalSeniorDepositor("EXOGENOUS_SENIOR_JOINER", assets);
        assertGt(stShares, 0, "arrange: the real senior deposit must mint shares");

        // The real deposit is a kernel op that commits, so the exogenous window baseline is captured after it
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        uint256 lptOwned0 = toUint256(KERNEL.getState().totalLPTAssets);
        uint256 kernelBPT0 = IERC20(POOL).balanceOf(address(KERNEL));
        uint256 w0 = _stValueShareWAD();
        uint256 spot0 = _spotSTinQuoteWAD();
        uint256 navPerBPT0 = _navPerBPTWAD();
        uint256 invTol = _navPerBPTInvariantErrorTolerance(navPerBPT0);
        uint256 valueIn = _stSharesToNAVAtRate(stShares, _kernelRate());

        uint256 bptOut = _externalAddUnbalanced(actor, stShares, 0, 0);

        assertEq(IERC20(POOL).balanceOf(actor), bptOut, "the minted BPT must land with the external actor");
        assertEq(IERC20(POOL).balanceOf(address(KERNEL)), kernelBPT0, "the kernel's BPT balance must be untouched");
        int256 leak = int256(valueIn) - int256(Math.mulDiv(bptOut, _mtmPerBPTWAD(), WAD));
        (int256 expectedLeak, uint256 slack) = _expectedSingleSidedAddLeak(valueIn, w0, spot0, _spotSTinQuoteWAD());
        assertApproxEqAbs(leak, expectedLeak, slack, "the senior-side join leak must match (1-w)*V*(f + (1-q))");
        _assertStepNonDilutive(navPerBPT0, invTol, "single-sided senior join");
        _assertCheckpointAndLedgerUntouched(a0, lptOwned0, "single-sided senior join");
    }

    /**
     * @notice the full external liquidity matrix run back to back (proportional join, single-sided quote join,
     *         single-sided senior join from a real deposit, single-sided exit to quote, single-sided exit to
     *         senior, full proportional exit): after EVERY shape NAV per BPT never falls beyond the derived
     *         invariant-error tolerance, the kernel's owned-BPT ledger is byte-constant, and at the end the
     *         committed checkpoint is untouched across the whole exogenous window.
     */
    function test_ExogenousLiquidityMatrix_navPerBPTNeverDiluted_kernelLedgerConstant() public {
        _seedForSwaps();
        // The senior position is built FIRST through the real deposit flow (a kernel op that commits), so the
        // pure-exogenous window starts after it
        uint256 targetValue = _liveBalances()[_stPoolIndex()] / 20;
        (address seniorJoiner, uint256 stShares) = _makeExternalSeniorDepositor("MATRIX_SENIOR_JOINER", toUint256(KERNEL.convertValueToCollateralAssets(toNAVUnits(targetValue))));
        address quoteJoiner = _makeExternalLP("MATRIX_QUOTE_JOINER");
        uint256 quoteAssets = _rawBalances()[_quotePoolIndex()] / 20;
        _fundExternalLP(quoteJoiner, 0, quoteAssets);
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        uint256 lptOwned0 = toUint256(KERNEL.getState().totalLPTAssets);

        // 1. proportional join (10% of the supply)
        uint256 navPre = _navPerBPTWAD();
        uint256 tol = _navPerBPTInvariantErrorTolerance(navPre);
        address propJoiner = _externalProportionalPosition("MATRIX_PROP_JOINER", _bptSupply() / 10);
        _assertStepNonDilutive(navPre, tol, "proportional join");
        assertEq(toUint256(KERNEL.getState().totalLPTAssets), lptOwned0, "ledger moved: proportional join");

        // 2. single-sided quote join
        navPre = _navPerBPTWAD();
        tol = _navPerBPTInvariantErrorTolerance(navPre);
        uint256 quoteBPT = _externalAddUnbalanced(quoteJoiner, 0, quoteAssets, 0);
        _assertStepNonDilutive(navPre, tol, "single-sided quote join");
        assertEq(toUint256(KERNEL.getState().totalLPTAssets), lptOwned0, "ledger moved: single-sided quote join");

        // 3. single-sided senior join from the real-deposit position
        navPre = _navPerBPTWAD();
        tol = _navPerBPTInvariantErrorTolerance(navPre);
        uint256 seniorBPT = _externalAddUnbalanced(seniorJoiner, stShares, 0, 0);
        _assertStepNonDilutive(navPre, tol, "single-sided senior join");
        assertEq(toUint256(KERNEL.getState().totalLPTAssets), lptOwned0, "ledger moved: single-sided senior join");

        // 4. single-sided exit to quote
        navPre = _navPerBPTWAD();
        tol = _navPerBPTInvariantErrorTolerance(navPre);
        _externalRemoveSingleTokenExactIn(quoteJoiner, quoteBPT / 2, testConfig.quoteAsset);
        _assertStepNonDilutive(navPre, tol, "single-sided quote exit");
        assertEq(toUint256(KERNEL.getState().totalLPTAssets), lptOwned0, "ledger moved: single-sided quote exit");

        // 5. single-sided exit to the senior share
        navPre = _navPerBPTWAD();
        tol = _navPerBPTInvariantErrorTolerance(navPre);
        _externalRemoveSingleTokenExactIn(seniorJoiner, seniorBPT / 2, address(ST));
        _assertStepNonDilutive(navPre, tol, "single-sided senior exit");
        assertEq(toUint256(KERNEL.getState().totalLPTAssets), lptOwned0, "ledger moved: single-sided senior exit");

        // 6. full proportional exit
        navPre = _navPerBPTWAD();
        tol = _navPerBPTInvariantErrorTolerance(navPre);
        _externalRemoveProportional(propJoiner, IERC20(POOL).balanceOf(propJoiner));
        _assertStepNonDilutive(navPre, tol, "proportional exit");

        // The whole exogenous window never touched the committed checkpoint or the kernel's ledger
        _assertCheckpointAndLedgerUntouched(a0, lptOwned0, "end of the exogenous matrix");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // C — ROYCO OPS COMPOSED WITH EXOGENOUS DRIFT
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice a senior deposit sized by the POST-drift advertised max executes after an exogenous swap moved
     *         the pool, and the next slack-sized deposit is rejected by the liquidity gate judging the
     *         post-drift COMMITTED mark (the op's own pre-op sync commits the drifted mark before gating).
     * @dev Drift direction derivation: exogenous flow moves the invariant-based mark only UP (retained fees
     *      grow the invariant, joins and exits are supply-proportional up to fees), so the post-drift
     *      advertised max weakly dominates the pre-drift one and the stale-maxima revert branch is
     *      unreachable for the senior gate on this venue, which the GE below pins.
     */
    function test_STDeposit_afterExogenousDrift_gateJudgesPostDriftCommittedMark() public {
        _seedForSwaps();
        _driveLiquidityUtilizationTo(0.99e18);
        uint256 maxPre = toUint256(ST.maxDeposit(ST_BOB_ADDRESS));
        assertGt(maxPre, 0, "arrange: the tight gate must still advertise headroom");

        // Exogenous drift: a half-capacity swap, whose retained fee lifts the markable pool NAV
        _skewPool(true, 0.5e18);
        uint256 maxPost = toUint256(ST.maxDeposit(ST_BOB_ADDRESS));
        assertGe(maxPost, maxPre, "exogenous drift can only widen the senior gate's headroom");

        // The post-drift advertised max executes (snapshot leg, so the breach prices off the same base state)
        uint256 snapshotId = vm.snapshotState();
        uint256 shares = _doDepositST(ST_BOB_ADDRESS, maxPost).shares;
        assertGt(shares, 0, "the post-drift advertised max must execute");
        assertLe(_committedLiquidityUtilization(), WAD, "the max-sized deposit must respect the committed gate");
        vm.revertToState(snapshotId);

        // Beyond the post-drift boundary the gate rejects with its own selector. Slack derivation: maxDeposit
        // under-reports the boundary by at most the dust tolerance plus conversion floors, so exceeding it by
        // the documented 2 * dust + 6 slack in ONE deposit guarantees the breach (see _stMaxDepositBreachSlackAssets)
        uint256 breachAssets = maxPost + _stMaxDepositBreachSlackAssets();
        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(COLLATERAL_ASSET).approve(address(ST), breachAssets);
        vm.expectRevert(IRoycoDayKernel.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        ST.deposit(toTrancheUnits(breachAssets), ST_BOB_ADDRESS);
        vm.stopPrank();
    }

    /**
     * @notice after an exogenous skew, the LPT multi-asset deposit's same-block preview equals its execution
     *         to the wei, the fresh advertised BPT floor executes at exactly its own min, and a stale
     *         pre-drift floor is rejected inside Balancer with the exact-args venue selector when the drift
     *         reduced the mint (either outcome is legal per spec, the branch asserts the selector on revert).
     */
    function test_LPTDepositMulti_afterExogenousDrift_previewExecParityAndFloors() public {
        _seedForSwaps();
        _sync();
        uint256 stLeg = _rawBalances()[_stPoolIndex()] / 20;
        uint256 quoteLeg = _quoteAssetsForValue(KERNEL.convertCollateralAssetsToValue(toTrancheUnits(stLeg)));
        (, uint256 staleBptOut) = _previewDepositLPTMultiFull(stLeg, quoteLeg);
        assertGt(staleBptOut, 0, "arrange: the pre-drift preview must quote a mint");

        _skewPool(true, 0.6e18);
        (uint256 freshShares, uint256 freshBptOut) = _previewDepositLPTMultiFull(stLeg, quoteLeg);

        // Stale-floor branch: deterministic at the pinned fork block, selector asserted whenever it reverts
        if (staleBptOut > freshBptOut) {
            vm.startPrank(LPT_ALICE_ADDRESS);
            IERC20(COLLATERAL_ASSET).approve(address(LPT), stLeg);
            IERC20(testConfig.quoteAsset).approve(address(LPT), quoteLeg);
            vm.expectRevert(abi.encodeWithSelector(IVaultErrors.BptAmountOutBelowMin.selector, freshBptOut, staleBptOut));
            IRoycoLiquidityProviderTranche(address(LPT)).depositMultiAsset(stLeg, quoteLeg, staleBptOut, LPT_ALICE_ADDRESS);
            vm.stopPrank();
        }

        // Same-block post-drift parity at the fresh advertised floor: quote == execution to the wei
        OpReceipt memory r = _doDepositLPTMulti(LPT_ALICE_ADDRESS, stLeg, quoteLeg, freshBptOut);
        assertEq(r.shares, freshShares, "the post-drift preview must equal the executed shares to the wei");
    }

    /**
     * @notice after an exogenous skew drains the pool's senior leg, a multi-asset redemption's STALE pre-drift
     *         senior min-out is rejected inside Balancer with exact args and full atomicity, while the fresh
     *         post-drift floor executes. Min-out floors judge the venue's post-drift execution, never a stale quote.
     */
    function test_LPTRedeemMulti_afterExogenousDrift_staleMinOutRejected_freshExecutes() public {
        _seedForSwaps();
        _sync();
        assertEq(KERNEL.getState().lptOwnedSeniorTrancheShares, 0, "arrange: no staged premium may pollute the burned-supply measurement");
        uint256 shares = LPT.balanceOf(LPT_ALICE_ADDRESS) / 4;

        // Pre-drift venue senior leg, measured by a snapshot-reverted execution probe (burned supply delta)
        uint256 snapshotId = vm.snapshotState();
        uint256 stSupply0 = ST.totalSupply();
        _doRedeemLPTMulti(LPT_ALICE_ADDRESS, shares, 0, 0);
        uint256 staleVenueSTOut = stSupply0 - ST.totalSupply();
        vm.revertToState(snapshotId);
        assertGt(staleVenueSTOut, 0, "arrange: the venue must withdraw senior shares pre-drift");

        // Exogenous drift: buying the senior leg drains it, the proportional unwind now pays fewer senior shares
        _skewPool(true, 0.6e18);
        snapshotId = vm.snapshotState();
        stSupply0 = ST.totalSupply();
        _doRedeemLPTMulti(LPT_ALICE_ADDRESS, shares, 0, 0);
        uint256 freshVenueSTOut = stSupply0 - ST.totalSupply();
        vm.revertToState(snapshotId);
        assertLt(freshVenueSTOut, staleVenueSTOut, "arrange: the drift must strictly reduce the venue's senior leg");

        // The stale floor is rejected with exact args and the market is untouched (atomicity)
        MarketSnapshot memory pre = _snap();
        vm.prank(LPT_ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.AmountOutBelowMin.selector, address(ST), freshVenueSTOut, staleVenueSTOut));
        IRoycoLiquidityProviderTranche(address(LPT)).redeemMultiAsset(shares, staleVenueSTOut, 0, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);
        _assertMarketUnchanged(pre);

        // The fresh post-drift floor executes at exactly its own boundary
        vm.prank(LPT_ALICE_ADDRESS);
        IRoycoLiquidityProviderTranche(address(LPT)).redeemMultiAsset(shares, freshVenueSTOut, 0, LPT_ALICE_ADDRESS, LPT_ALICE_ADDRESS);
    }

    /**
     * @notice the reinvest's slippage gate judges the venue's POST-drift realized execution: a gate set
     *         strictly between the pre-drift and post-drift measured haircuts deploys the staged premium
     *         before the exogenous skew and tolerate-fails after it, with the premium left staged.
     */
    function test_Reinvest_afterExogenousDrift_slippageGateJudgesPostDriftExecution() public {
        _arrangeReinvestableIdleLiquidityPremium();
        (uint256 haircutPre,) = _probeReinvestHaircutWAD();

        // Measure the post-drift haircut under a reverted snapshot: selling senior into the pool makes the
        // single-sided senior deploy maximally imbalanced
        uint256 snapshotId = vm.snapshotState();
        _skewPool(false, 0.5e18);
        (uint256 haircutPost,) = _probeReinvestHaircutWAD();
        vm.revertToState(snapshotId);
        // The strict interior gate exists only when the two measurements are more than one wei apart
        assertGt(haircutPost, haircutPre + 1, "arrange: the drift must strictly worsen the realized haircut");

        uint64 gate = uint64(haircutPre + (haircutPost - haircutPre) / 2);
        assertTrue(_trySetReinvestmentSlippage(gate), "arrange: the interior gate must set");
        (uint256 idleShares0,) = _idleLiquidityPremiumValueNAV();

        // Pre-drift the gate clears and the premium deploys (snapshot-reverted control leg)
        snapshotId = vm.snapshotState();
        (,, uint256 eventCount) = _manualReinvestAll();
        assertEq(eventCount, 1, "pre-drift the interior gate must deploy");
        vm.revertToState(snapshotId);

        // Post-drift the SAME gate rejects the realized execution and the premium stays staged
        _skewPool(false, 0.5e18);
        (,, uint256 eventCountPost) = _manualReinvestAll();
        assertEq(eventCountPost, 0, "post-drift the same gate must tolerate-fail on the realized execution");
        assertEq(KERNEL.getState().lptOwnedSeniorTrancheShares, idleShares0, "the premium must stay staged for the next attempt");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // D — DONATIONS + THE RATE SURFACE
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice direct token donations to the Vault and to the pool contract (senior shares and quote) are
     *         FULLY inert: pool balances, the oracle TVL, swap quotes, and every committed mark are
     *         byte-identical before and after, including across a sync.
     * @dev Balancer V3 books pool balances in its internal ledger and recognizes token movement only through
     *      a session's settle, so unsolicited transfers are unaccounted surplus. The venue's marks are
     *      ledger-priced, not balance-priced, so no composition drift and no tranche NAV jump is reachable by
     *      donation. Donations are real transfers from funded donors, never balance overwrites.
     */
    function test_DonationToVaultAndPool_inertToPoolAccountingAndCommittedMarks() public {
        _seedForSwaps();
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        uint256[] memory raw0 = _rawBalances();
        uint256 tvl0 = _poolTVL();
        uint256 lptLive0 = toUint256(_liveLPTRawNAV());
        uint256 refAmountIn = _maxSwapInBeforeRangeRevert(testConfig.quoteAsset) / 4;
        (bool okA, uint256 quoteBefore) = _querySwapExactIn(testConfig.quoteAsset, address(ST), refAmountIn);
        assertTrue(okA, "arrange: the reference quote must succeed");

        // Donate the senior share and the quote asset to the Vault, and the senior share to the pool contract
        uint256 stDonation = raw0[_stPoolIndex()] / 100;
        uint256 quoteDonation = raw0[_quotePoolIndex()] / 100;
        vm.startPrank(ST_ALICE_ADDRESS);
        IERC20(address(ST)).transfer(address(VAULT), stDonation);
        IERC20(address(ST)).transfer(POOL, stDonation);
        vm.stopPrank();
        address donor = makeAddr("QUOTE_DONOR");
        dealQuoteAsset(donor, quoteDonation);
        vm.prank(donor);
        IERC20(testConfig.quoteAsset).transfer(address(VAULT), quoteDonation);

        // The pool's internal accounting, the oracle, and pricing are untouched
        uint256[] memory raw1 = _rawBalances();
        assertEq(raw1[0], raw0[0], "a donation must not move pool balance 0");
        assertEq(raw1[1], raw0[1], "a donation must not move pool balance 1");
        assertEq(_poolTVL(), tvl0, "a donation must not move the oracle TVL");
        assertEq(toUint256(_liveLPTRawNAV()), lptLive0, "a donation must not move the live LPT mark");
        (bool okB, uint256 quoteAfter) = _querySwapExactIn(testConfig.quoteAsset, address(ST), refAmountIn);
        assertTrue(okB, "the reference quote must still succeed");
        assertEq(quoteAfter, quoteBefore, "a donation must be invisible to swap pricing");

        // A sync commits nothing new: every mark is byte-identical
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a1 = ACCOUNTANT.getState();
        assertEq(a1.lastCollateralNAV, a0.lastCollateralNAV, "the collateral mark must ignore donations");
        assertEq(a1.lastSTEffectiveNAV, a0.lastSTEffectiveNAV, "the senior mark must ignore donations");
        assertEq(a1.lastJTEffectiveNAV, a0.lastJTEffectiveNAV, "the junior mark must ignore donations");
        assertEq(a1.lastLPTRawNAV, a0.lastLPTRawNAV, "the LPT mark must ignore donations");
    }

    /**
     * @notice the rate the pool swaps at is the LIVE recomputed kernel rate: an exogenous senior-supply-moving
     *         action (a REAL third-party senior deposit) is visible to the next swap's rate because the
     *         operation-scoped price cache is cleared between ops, and the post-deposit rate equals the
     *         committed NAV per POST-deposit effective share exactly.
     * @dev Deposit-side bound derivation: the mint floors shares down against the effective supply, so a fair
     *      deposit moves NAV per share only weakly up, never down by more than the read's own floor (1 wei).
     */
    function test_GetRate_exogenousSeniorSupplyMove_visibleToNextSwapRate() public {
        _seedForSwaps();
        _sync();
        uint256 rate0 = _kernelRate();
        uint256 supply0 = ST.totalSupply();

        // Exogenous supply move through the real deposit flow
        _makeExternalSeniorDepositor("EXOGENOUS_RATE_SUPPLY_MOVER", testConfig.initialFunding / 100);
        assertGt(ST.totalSupply(), supply0, "arrange: the senior supply must have moved");

        // The op-scoped cache is cleared at the deposit frame's exit: the next read prices the NEW supply
        uint256 expected = Math.mulDiv(WAD, toUint256(ACCOUNTANT.getState().lastSTEffectiveNAV) + VIRTUAL_VALUE, ST.totalSupply() + VIRTUAL_SHARES);
        assertEq(_kernelRate(), expected, "getRate must reprice at the post-deposit committed state and supply");
        assertGe(_kernelRate() + 1, rate0, "a fair-priced deposit can only move NAV per share weakly up (1 wei floor)");

        // The next swap settles at the post-move quote and the Vault's rate view reads exactly this live rate
        (address swapper, uint256 amountIn) = _armSwapper(testConfig.quoteAsset, 0.1e18);
        (bool ok, uint256 quoted) = _querySwapExactIn(testConfig.quoteAsset, address(ST), amountIn);
        assertTrue(ok, "arrange: the post-move quote must succeed");
        uint256 amountOut = _swapExactIn(swapper, testConfig.quoteAsset, address(ST), amountIn, quoted);
        assertEq(amountOut, quoted, "the swap must settle at the post-supply-move quote");
        (, uint256[] memory tokenRates) = VAULT.getPoolTokenRates(POOL);
        assertEq(tokenRates[_stPoolIndex()], _kernelRate(), "the pool's senior-leg rate must be the live recomputed kernel rate");
        assertEq(tokenRates[_stPoolIndex()], expected, "the swap-facing rate must carry the exogenous supply move");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // E — VAULT SESSION BOUNDARIES
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice a Royco venue operation can NEVER run inside a session an exogenous party opened: both venue
     *         dispatch surfaces (the multi-asset deposit's addLiquidity and the redemption's removeLiquidity)
     *         refuse a pre-unlocked Vault with `VAULT_ALREADY_UNLOCKED`, and the identical calls succeed
     *         outside the session, so the guard keys on the session alone.
     * @dev The probe relays the permissionless preview surface, which routes through the very same
     *      `whenVaultLocked` modifier the execute path carries (the modifier sits on the shared venue op, not
     *      the dispatch mode), so the pin covers both transports.
     */
    function test_RevertIf_RoycoVenueOpDispatchedInsideForeignUnlockSession() public {
        _seedForSwaps();
        _sync();
        VaultSessionProbe probe = new VaultSessionProbe(VAULT);
        uint256 stLeg = 1e18;
        uint256 quoteLeg = _quoteScale();

        bytes memory depositPreview = abi.encodeCall(IRoycoLiquidityProviderTranche.previewDepositMultiAsset, (stLeg, quoteLeg));
        vm.expectRevert(BalancerV3LiquidityVenue.VAULT_ALREADY_UNLOCKED.selector);
        probe.openSessionAndCall(address(LPT), depositPreview);

        bytes memory redeemPreview = abi.encodeCall(IRoycoLiquidityProviderTranche.previewRedeemMultiAsset, (LPT.totalSupply() / 100));
        vm.expectRevert(BalancerV3LiquidityVenue.VAULT_ALREADY_UNLOCKED.selector);
        probe.openSessionAndCall(address(LPT), redeemPreview);

        // Outside any session the identical previews pass: the guard keys on the open session, nothing else
        (uint256 shares,) = _previewDepositLPTMultiFull(stLeg, quoteLeg);
        assertGt(shares, 0, "the identical preview must succeed outside the foreign session");
    }

    /**
     * @notice the Vault's own session guards hold against an exogenous party on both sides: a Vault op
     *         invoked with no session open reverts `VaultIsNotUnlocked`, and a party that opens its OWN
     *         session cannot leave it holding unsettled Vault value (`BalanceNotSettled` unwinds the whole
     *         session, so pulling pool-backed tokens without paying is unreachable).
     */
    function test_RevertIf_DirectVaultOpOutsideSession_orUnsettledSessionExit() public {
        _seedForSwaps();
        _sync();

        // Locked vault: the marquee op (swap) is rejected before touching any pool state
        VaultSwapParams memory params = VaultSwapParams({
            kind: SwapKind.EXACT_IN,
            pool: POOL,
            tokenIn: IERC20(testConfig.quoteAsset),
            tokenOut: IERC20(address(ST)),
            amountGivenRaw: _quoteScale(),
            limitRaw: 0,
            userData: ""
        });
        vm.expectRevert(IVaultErrors.VaultIsNotUnlocked.selector);
        VAULT.swap(params);

        // An exogenous session owner sends itself pool-backed quote tokens and exits without settling: the
        // session guard unwinds the whole unlock, so the theft never lands
        VaultSessionProbe probe = new VaultSessionProbe(VAULT);
        uint256 loot = _rawBalances()[_quotePoolIndex()] / 10;
        bytes memory sendToCall = abi.encodeCall(IVaultMain.sendTo, (IERC20(testConfig.quoteAsset), address(probe), loot));
        vm.expectRevert(IVaultErrors.BalanceNotSettled.selector);
        probe.openSessionAndCall(address(VAULT), sendToCall);
        assertEq(IERC20(testConfig.quoteAsset).balanceOf(address(probe)), 0, "the unsettled session's takings must be fully unwound");
    }
}
