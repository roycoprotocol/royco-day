// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Errors } from "../../../lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { JT_LP_ROLE, LT_LP_ROLE, ST_LP_ROLE } from "../../../src/factory/RolesConfiguration.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { MarketState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MarketParamsConfig } from "../../base/fixtures/FixtureTypes.sol";
import { defaultParams, zeroLiquidityParams } from "../../base/fixtures/MarketParams.sol";
import { cellA } from "../../base/fixtures/TokenConfigs.sol";
import { TrancheFixture } from "../../base/fixtures/TrancheFixture.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";

/**
 * @title DayMarketHandler
 * @notice Stateful-invariant handler driving a full mock Day market through every tranche flow, sync,
 *         reinvestment, time, PnL injection, admin nudges, and external pool activity
 * @dev Every op runs in three phases. First a keeper sync whose full outcome is verified against an
 *      independent recomputation (the waterfall mirror, the premium carve-out mirror, the accrual-window
 *      mirror, the pool-mark mirror). Second the op itself, executed under a revert prediction computed
 *      from the freshly committed state with the independent gate formulas, so the op may be observed to
 *      revert only for a reason the handler derived on its own. Third a trailing verified sync that
 *      realizes and checks the op's effects. An unpredicted revert, a failed sync, or any mismatch against
 *      a mirror records a violation that the invariant contract asserts empty after every call, so nothing
 *      is ever silently swallowed
 * @dev Ops never early-return on a live market. Degenerate states (an empty tranche, an already-breached
 *      threshold) are recognized by recomputing the same gate the production code enforces, and the op then
 *      either asserts the predicted revert or performs its recorded no-op, never a blind skip
 */
contract DayMarketHandler is TrancheFixture {
    using Math for uint256;

    // =============================
    // Immutable profile and derived constants
    // =============================

    /// @notice Whether this market runs the zero-minimum-liquidity reduction profile
    bool public immutable IS_ZERO_LIQUIDITY_PROFILE;

    /// @dev One whole quote token in its native decimals
    uint256 internal QUOTE_UNIT;

    /// @dev Whether the junior tranche is co-invested (always true for this kernel family)
    bool internal JT_CO;

    /// @dev The pinned instantaneous junior yield share the mock model returns on every query
    uint256 internal JT_PINNED_SHARE_WAD;

    /// @dev The pinned instantaneous liquidity yield share the mock model returns on every query
    uint256 internal LT_PINNED_SHARE_WAD;

    /**
     * @dev Worst-case NAV-wei lost to flooring across one operation's unit conversions and claim scalings.
     *      A single mulDiv floor loses under 1 wei of its result and one op performs at most ten of them
     *      (two quoter conversions per leg, the five claim fields, the post-op delta), each worth at most
     *      the share-rate in NAV wei. The share rate stays below 10 under the bounded PnL regime, so 100
     *      NAV wei bounds the total. Used only to tolerate flooring in the share-price monotonicity check
     */
    uint256 internal constant PRICE_FLOOR_DUST_NAV_WEI_DERIVED_BOUND = 100;

    // =============================
    // Actors
    // =============================

    address[3] internal stActors;
    address[2] internal jtActors;
    address[2] internal ltActors;
    address internal externalLp;

    // =============================
    // Violation recording (the invariant contract asserts these empty)
    // =============================

    /// @notice The first recorded violation message, empty while the run is healthy
    string public ghost_violation;

    /// @notice The number of violations recorded so far
    uint256 public ghost_violationCount;

    // =============================
    // Ghost ledgers
    // =============================

    /// @notice Cumulative token amounts actors transferred into the market, per asset
    mapping(address token => uint256) public ghost_transferredIn;

    /// @notice Cumulative token amounts receivers took out of the market, per asset
    mapping(address token => uint256) public ghost_transferredOut;

    /// @notice Cumulative liquidity-premium senior shares minted to the market for the liquidity tranche
    uint256 public ghost_premiumSharesMinted;

    /// @notice Cumulative idle premium senior shares deployed into the pool, measured at the pool's own balance
    uint256 public ghost_premiumSharesReinvested;

    /// @notice Cumulative idle premium senior shares handed directly to redeemers
    uint256 public ghost_idleSharesPaidToRedeemers;

    /// @dev The cause of one recorded coverage-loss ledger movement
    enum ILCause {
        COVERAGE_APPLIED,
        RECOVERY,
        JT_REDEEM_SCALE,
        ERASED
    }

    /// @dev One recorded coverage-loss ledger movement
    struct ILEvent {
        ILCause cause;
        uint256 magnitude;
    }

    /// @notice The append-only log of every coverage-loss ledger movement with its cause
    ILEvent[] public ghost_ilEvents;

    /// @dev The coverage-loss value implied by replaying the event log, checked against the committed value
    uint256 internal ghost_ilReplay;

    // =============================
    // Share-price monotonicity trackers
    // =============================

    uint256 internal ghost_stPriceHighWater;
    uint256 internal ghost_jtPriceHighWater;
    uint256 internal ghost_ltPriceHighWater;

    /// @dev Set by ops that can legitimately push the senior share price down (an uncovered drawdown)
    bool internal ghost_uncoveredLossSinceLastCheck;

    /// @dev Set by ops that can legitimately push the junior share price down (losses, coverage, exit bonuses)
    bool internal ghost_jtLossSinceLastCheck;

    /// @dev Set by ops that can legitimately push the liquidity share price down (a venue drawdown)
    bool internal ghost_ltVenueLossSinceLastCheck;

    // =============================
    // Accrual-window mirror state
    // =============================

    /// @dev The largest configured junior yield-share cap seen inside the current premium window
    uint256 internal ghost_windowMaxJTShareWAD;

    /// @dev The largest configured liquidity yield-share cap seen inside the current premium window
    uint256 internal ghost_windowMaxLTShareWAD;

    // =============================
    // Regime counters (reported by the invariant contract)
    // =============================

    uint256 public ghost_enteredFixedTerm;
    uint256 public ghost_exitedFixedTerm;
    uint256 public ghost_crossedLiquidationThreshold;
    uint256 public ghost_stagedPremiumObserved;
    uint256 public ghost_zeroSupplyStatesReached;
    uint256 public ghost_syncCount;
    uint256 public ghost_uncoveredLossRealized;

    /// @notice Successful executions per op label
    mapping(bytes32 op => uint256) public ghost_opSuccesses;

    /// @notice Predicted (and observed) gate rejections per op label
    mapping(bytes32 op => uint256) public ghost_opPredictedReverts;

    /// @notice Whether the venue is armed to fail single-sided reinvestments with a punitive haircut
    bool public ghost_venueSlippageArmed;

    // =============================
    // Predicted-revert machinery
    // =============================

    /// @dev A bounded buffer of revert selectors the current op is allowed to produce
    struct Pred {
        bytes4[12] sels;
        uint256 n;
    }

    bytes4 internal constant SEL_DISABLED_FT = IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector;
    bytes4 internal constant SEL_COVERAGE = IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector;
    bytes4 internal constant SEL_LIQUIDITY = IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector;
    bytes4 internal constant SEL_INVALID_POST_OP = IRoycoDayAccountant.INVALID_POST_OP_STATE.selector;
    bytes4 internal constant SEL_ZERO_SHARES = IRoycoVaultTranche.MUST_MINT_NON_ZERO_SHARES.selector;
    bytes4 internal constant SEL_ZERO_VALUE = IRoycoVaultTranche.INVALID_VALUE_ALLOCATED.selector;
    bytes4 internal constant SEL_ZERO_REDEEM = IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector;
    bytes4 internal constant SEL_ERC20_BALANCE = IERC20Errors.ERC20InsufficientBalance.selector;
    bytes4 internal constant SEL_PANIC = bytes4(0x4e487b71);

    // =============================
    // Committed-state snapshot taken right after a verified sync
    // =============================

    /// @dev Everything an op needs to predict its own gates, read from freshly committed state
    struct Snap {
        bool ok;
        bool fixedTerm;
        uint256 stRaw;
        uint256 jtRaw;
        uint256 ltRaw;
        uint256 stEff;
        uint256 jtEff;
        uint256 il;
        uint256 covUtil;
        uint256 minCov;
        uint256 minLiq;
        uint256 covLiqUtil;
        uint256 effDust;
        uint256 stSupply;
        uint256 jtSupply;
        uint256 ltSupply;
        uint256 stOwned;
        uint256 jtOwned;
        uint256 ltOwned;
        uint256 idle;
        uint256 bonusWAD;
    }

    // =============================
    // Construction
    // =============================

    /// @dev Guards init against a second call
    bool internal initialized;

    /// @notice Records the profile only, the market deploys in init once this contract has code
    /// @param _zeroLiquidityProfile Whether to run the zero-minimum-liquidity reduction market
    constructor(bool _zeroLiquidityProfile) {
        IS_ZERO_LIQUIDITY_PROFILE = _zeroLiquidityProfile;
    }

    /// @notice Deploys, seeds, and baselines the market, callable once from the invariant contract's setUp
    /// @dev Split from the constructor because the verified sync self-calls this contract, which has no code mid-construction
    function init() external {
        require(!initialized, "already initialized");
        initialized = true;
        MarketParamsConfig memory p = IS_ZERO_LIQUIDITY_PROFILE ? zeroLiquidityParams() : defaultParams();
        _deployMarket(cellA(), p);

        QUOTE_UNIT = 10 ** uint256(cell.quoteAsset.decimals);
        JT_CO = accountant.JT_COINVESTED();
        JT_PINNED_SHARE_WAD = uint256(params.jtCurve[1]);
        LT_PINNED_SHARE_WAD = uint256(params.ltCurve[1]);
        ghost_windowMaxJTShareWAD = params.maxJTYieldShareWAD;
        ghost_windowMaxLTShareWAD = params.maxLTYieldShareWAD;

        // Actor set: three senior LPs, two junior LPs, two liquidity LPs, one external pool participant
        stActors[0] = _generateActor("H_ST_ACTOR_0", ST_LP_ROLE);
        stActors[1] = _generateActor("H_ST_ACTOR_1", ST_LP_ROLE);
        stActors[2] = _generateActor("H_ST_ACTOR_2", ST_LP_ROLE);
        jtActors[0] = _generateActor("H_JT_ACTOR_0", JT_LP_ROLE);
        jtActors[1] = _generateActor("H_JT_ACTOR_1", JT_LP_ROLE);
        ltActors[0] = _generateActor("H_LT_ACTOR_0", LT_LP_ROLE);
        ltActors[1] = _generateActor("H_LT_ACTOR_1", LT_LP_ROLE);
        externalLp = makeAddr("H_EXTERNAL_LP");

        // Seed a healthy market: 30k junior first (coverage), auto-seeded quote depth, then 100k senior
        _seedMarket(100_000e18, 30_000e18);

        // Baseline the ghost ledgers and the price high-water marks off one verified sync
        _syncAndVerify("constructor");
        ghost_transferredIn[address(stJtVault)] = stJtVault.balanceOf(address(kernel));
        ghost_ilReplay = toUint256(accountant.getState().lastJTCoverageImpermanentLoss);
    }

    // =============================
    // Weighted ops
    // =============================

    /// @notice A senior LP deposits vault shares through the production deposit path
    function op_stDeposit(uint256 _actorSeed, uint256 _assets) external {
        address actor = stActors[bound(_actorSeed, 0, stActors.length - 1)];
        // Uniform over 1e-6 to 1e6 whole vault shares, wide enough to press the coverage and liquidity gates
        uint256 assets = bound(_assets, 1e12, 1e24);
        Snap memory s = _syncAndVerify("pre:stDeposit");
        if (s.ok) {
            _execStDeposit(actor, assets, s);
            _syncAndVerify("post:stDeposit");
        }
    }

    /// @notice A senior LP redeems shares, receiving its slice of the senior and junior asset pools
    function op_stRedeem(uint256 _actorSeed, uint256 _shares) external {
        address actor = stActors[bound(_actorSeed, 0, stActors.length - 1)];
        Snap memory s = _syncAndVerify("pre:stRedeem");
        if (s.ok) {
            uint256 bal = seniorTranche.balanceOf(actor);
            // Uniform over the actor's holding, degraded to a single share on an empty balance so the
            // insufficient-balance revert is asserted instead of skipped
            uint256 shares = bound(_shares, 1, bal == 0 ? 1 : bal);
            _execStRedeem(actor, shares, s);
            _syncAndVerify("post:stRedeem");
        }
    }

    /// @notice A junior LP deposits vault shares, growing the loss-absorption buffer
    function op_jtDeposit(uint256 _actorSeed, uint256 _assets) external {
        address actor = jtActors[bound(_actorSeed, 0, jtActors.length - 1)];
        // Uniform over 1e-6 to 1e6 whole vault shares
        uint256 assets = bound(_assets, 1e12, 1e24);
        Snap memory s = _syncAndVerify("pre:jtDeposit");
        if (s.ok) {
            Pred memory p;
            uint256 value = _quoteSTUnits(assets);
            if (s.fixedTerm) {
                _expect(p, SEL_DISABLED_FT);
            } else {
                uint256 jtRawAfter = _quoteJTUnits(s.jtOwned + assets);
                if (jtRawAfter == s.jtRaw || value == 0) {
                    _expect(p, SEL_INVALID_POST_OP);
                    _expect(p, SEL_ZERO_VALUE);
                }
                if (RoycoTestMath.sharesFor(value, s.jtEff, s.jtSupply) == 0) _expect(p, SEL_ZERO_SHARES);
            }
            stJtVault.mintShares(actor, assets);
            vm.startPrank(actor);
            stJtVault.approve(address(juniorTranche), assets);
            try juniorTranche.deposit(toTrancheUnits(assets), actor) returns (uint256 gotShares) {
                _recordSuccess("jtDeposit");
                ghost_transferredIn[address(stJtVault)] += assets;
                _flag(gotShares == RoycoTestMath.sharesFor(value, s.jtEff, s.jtSupply), "jtDeposit minted shares diverge from the floor mirror");
            } catch (bytes memory err) {
                _classify("jtDeposit", err, p);
            }
            vm.stopPrank();
            _syncAndVerify("post:jtDeposit");
        }
    }

    /// @notice A junior LP redeems shares, bounded by the coverage the market must retain
    function op_jtRedeem(uint256 _actorSeed, uint256 _shares) external {
        address actor = jtActors[bound(_actorSeed, 0, jtActors.length - 1)];
        Snap memory s = _syncAndVerify("pre:jtRedeem");
        if (s.ok) {
            uint256 bal = juniorTranche.balanceOf(actor);
            // Uniform over the actor's holding, degraded to a single share on an empty balance
            uint256 shares = bound(_shares, 1, bal == 0 ? 1 : bal);
            _execJtRedeem(actor, shares, s);
            _syncAndVerify("post:jtRedeem");
        }
    }

    /// @notice A liquidity LP deposits pool tokens minted at fair value against a real quote leg
    function op_ltDeposit(uint256 _actorSeed, uint256 _quoteLeg) external {
        address actor = ltActors[bound(_actorSeed, 0, ltActors.length - 1)];
        // Uniform over 1 to 1e6 whole quote tokens backing the minted pool tokens
        uint256 quoteLeg = bound(_quoteLeg, QUOTE_UNIT, QUOTE_UNIT * 1e6);
        // Mint the pool tokens before the sync so the committed marks already reflect the deeper pool
        uint256 bptAmt = _mintFairValueBpt(actor, quoteLeg);
        Snap memory s = _syncAndVerify("pre:ltDeposit");
        if (s.ok) {
            Pred memory p;
            uint256 value = _quoteLTUnits(bptAmt);
            uint256 navAt = RoycoTestMath.ltEffNav(s.ltRaw, s.idle, s.stEff, s.stSupply);
            if (_quoteLTUnits(s.ltOwned + bptAmt) == s.ltRaw || value == 0) {
                _expect(p, SEL_INVALID_POST_OP);
                _expect(p, SEL_ZERO_VALUE);
            }
            if (RoycoTestMath.sharesFor(value, navAt, s.ltSupply) == 0) _expect(p, SEL_ZERO_SHARES);
            vm.startPrank(actor);
            bpt.approve(address(liquidityTranche), bptAmt);
            try liquidityTranche.deposit(toTrancheUnits(bptAmt), actor) returns (uint256 gotShares) {
                _recordSuccess("ltDeposit");
                ghost_transferredIn[address(bpt)] += bptAmt;
                _flag(gotShares == RoycoTestMath.sharesFor(value, navAt, s.ltSupply), "ltDeposit minted shares diverge from the floor mirror");
            } catch (bytes memory err) {
                _classify("ltDeposit", err, p);
            }
            vm.stopPrank();
            _syncAndVerify("post:ltDeposit");
        }
    }

    /// @notice A liquidity LP enters atomically with senior underlying plus quote through the venue add
    function op_ltDepositMultiAsset(uint256 _actorSeed, uint256 _stAssets, uint256 _quote) external {
        address actor = ltActors[bound(_actorSeed, 0, ltActors.length - 1)];
        // Uniform over 1e-6 to 1e6 whole vault shares on the senior leg and 1 to 1e6 quote tokens
        uint256 stAssets = bound(_stAssets, 1e12, 1e24);
        uint256 quoteAssets = bound(_quote, QUOTE_UNIT, QUOTE_UNIT * 1e6);
        Snap memory s = _syncAndVerify("pre:ltDepositMultiAsset");
        if (s.ok) {
            _execLtDepositMultiAsset(actor, stAssets, quoteAssets, s);
            _syncAndVerify("post:ltDepositMultiAsset");
        }
    }

    /// @notice A liquidity LP redeems in kind, taking pool tokens plus its slice of any staged premium shares
    function op_ltRedeem(uint256 _actorSeed, uint256 _shares) external {
        address actor = ltActors[bound(_actorSeed, 0, ltActors.length - 1)];
        Snap memory s = _syncAndVerify("pre:ltRedeem");
        if (s.ok) {
            uint256 bal = liquidityTranche.balanceOf(actor);
            // Uniform over the actor's holding, degraded to a single share on an empty balance
            uint256 shares = bound(_shares, 1, bal == 0 ? 1 : bal);
            _execLtRedeem(actor, shares, s);
            _syncAndVerify("post:ltRedeem");
        }
    }

    /// @notice A liquidity LP exits atomically, unwinding the senior leg back to vault shares plus quote
    function op_ltRedeemMultiAsset(uint256 _actorSeed, uint256 _shares) external {
        address actor = ltActors[bound(_actorSeed, 0, ltActors.length - 1)];
        Snap memory s = _syncAndVerify("pre:ltRedeemMultiAsset");
        if (s.ok) {
            uint256 bal = liquidityTranche.balanceOf(actor);
            // Uniform over the actor's holding, degraded to a single share on an empty balance
            uint256 shares = bound(_shares, 1, bal == 0 ? 1 : bal);
            _execLtRedeemMultiAsset(actor, shares, s);
            _syncAndVerify("post:ltRedeemMultiAsset");
        }
    }

    /// @notice The keeper synchronizes accounting with no accompanying operation
    function op_sync() external {
        _syncAndVerify("op:sync");
    }

    /// @notice The market operator attempts to deploy staged premium shares into the pool
    function op_reinvest(uint256 _stShares) external {
        Snap memory s = _syncAndVerify("pre:reinvest");
        if (s.ok) {
            // Half the calls deploy everything, half deploy an arbitrary partial amount
            uint256 amount = _stShares % 2 == 0 ? type(uint256).max : bound(_stShares, 1, s.idle == 0 ? 1 : s.idle);
            uint256 poolSeniorBefore = seniorTranche.balanceOf(address(balancerVault));
            uint256 idleBefore = kernel.getState().ltOwnedSeniorTrancheShares;
            vm.prank(MARKET_OPS_ADMIN);
            try kernel.reinvestLiquidityPremium(amount) {
                _recordSuccess("reinvest");
                uint256 deployed = seniorTranche.balanceOf(address(balancerVault)) - poolSeniorBefore;
                ghost_premiumSharesReinvested += deployed;
                _flag(
                    kernel.getState().ltOwnedSeniorTrancheShares == idleBefore - deployed,
                    "reinvest changed the staged premium ledger by more than the shares that reached the pool"
                );
            } catch (bytes memory err) {
                // The reinvestment path tolerates venue failures internally, so any revert is unpredicted
                Pred memory p;
                _classify("reinvest", err, p);
            }
            _syncAndVerify("post:reinvest");
        }
    }

    /// @notice Time passes and the price feed stays fresh, accruing premium weight without moving NAVs
    function op_warp(uint256 _seconds) external {
        // Uniform over one second to thirty days, long enough to let fixed terms elapse
        uint256 secs = bound(_seconds, 1, 30 days);
        _warpAndRefreshFeed(secs);
        _syncAndVerify("post:warp");
    }

    /// @notice The shared senior and junior underlying rate moves by a bounded basis-point amount
    function op_stPnL(int256 _bps) external {
        // Uniform over minus three to plus three percent per event, the realistic per-sync move
        int256 bps = bound(_bps, -300, 300);
        if (bps < 0) {
            ghost_uncoveredLossSinceLastCheck = true;
            ghost_jtLossSinceLastCheck = true;
            ghost_ltVenueLossSinceLastCheck = true;
        }
        applySTPnL(bps);
        _syncAndVerify("post:stPnL");
    }

    /// @notice An alias of the shared-rate move, kept as a distinct weighted action
    function op_jtPnL(int256 _bps) external {
        // Uniform over minus three to plus three percent per event
        int256 bps = bound(_bps, -300, 300);
        if (bps < 0) {
            ghost_uncoveredLossSinceLastCheck = true;
            ghost_jtLossSinceLastCheck = true;
            ghost_ltVenueLossSinceLastCheck = true;
        }
        applyJTPnL(bps);
        _syncAndVerify("post:jtPnL");
    }

    /// @notice The pool's quote leg moves by a bounded basis-point amount in both price stores
    function op_ltPnL(int256 _bps) external {
        // Uniform over minus three to plus three percent per event
        int256 bps = bound(_bps, -300, 300);
        if (bps < 0) ghost_ltVenueLossSinceLastCheck = true;
        applyLTPnL(bps);
        _syncAndVerify("post:ltPnL");
    }

    /// @notice The accountant admin nudges one market parameter within a safe, bounded range
    function op_adminParamNudge(uint256 _paramSeed, uint256 _valueSeed) external {
        Snap memory s = _syncAndVerify("pre:adminParamNudge");
        if (s.ok) {
            // Uniform over the five nudgeable parameter families
            uint256 kind = bound(_paramSeed, 0, 4);
            vm.startPrank(ACCOUNTANT_ADMIN);
            if (kind == 0 && !IS_ZERO_LIQUIDITY_PROFILE) {
                // Uniform over two to eight percent minimum liquidity
                accountant.setMinLiquidity(uint64(bound(_valueSeed, 0.02e18, 0.08e18)));
            } else if (kind == 1) {
                // Uniform over ten to thirty percent minimum coverage
                accountant.setMinCoverage(uint64(bound(_valueSeed, 0.1e18, 0.3e18)));
            } else if (kind == 2) {
                // Uniform over one-and-a-half to eight liquidation coverage utilization
                accountant.setLiquidationCoverageUtilization(bound(_valueSeed, 1.5e18, 8e18));
            } else if (kind == 3 && !IS_ZERO_LIQUIDITY_PROFILE) {
                // One of three fixed yield-share cap pairs that always sum below one hundred percent
                uint256 pick = bound(_valueSeed, 0, 2);
                (uint64 j, uint64 l) =
                    pick == 0 ? (uint64(0.5e18), uint64(0.3e18)) : pick == 1 ? (uint64(0.6e18), uint64(0.4e18)) : (uint64(0.4e18), uint64(0.2e18));
                accountant.setMaxYieldShares(j, l);
                if (j > ghost_windowMaxJTShareWAD) ghost_windowMaxJTShareWAD = j;
                if (l > ghost_windowMaxLTShareWAD) ghost_windowMaxLTShareWAD = l;
            } else if (kind == 4) {
                // One of three fixed term durations, never zero so the fixed-term regime stays reachable
                uint256 pick = bound(_valueSeed, 0, 2);
                accountant.setFixedTermDuration(pick == 0 ? 1 hours : pick == 1 ? 3 days : 2 weeks);
            }
            vm.stopPrank();
            _recordSuccess("adminParamNudge");
            _syncAndVerify("post:adminParamNudge");
        }
    }

    /// @notice An external participant joins the pool at fair value or donates one-sided quote depth
    function op_externalPoolOp(uint256 _kindSeed, uint256 _amount) external {
        // Uniform over one to ten thousand whole quote tokens
        uint256 amount = bound(_amount, QUOTE_UNIT, QUOTE_UNIT * 10_000);
        if (bound(_kindSeed, 0, 1) == 0) {
            // One-sided quote donation: drifts the pool composition and raises every pool mark
            quoteToken.mint(externalLp, amount);
            vm.startPrank(externalLp);
            quoteToken.approve(address(balancerVault), amount);
            balancerVault.injectPoolBalance(address(bpt), IERC20(address(quoteToken)), amount);
            vm.stopPrank();
        } else {
            // Fair-value external join: an outside LP now owns pool tokens the kernel does not control
            _mintFairValueBpt(externalLp, amount);
        }
        _recordSuccess("externalPoolOp");
        _syncAndVerify("post:externalPoolOp");
    }

    // =============================
    // Aimed ops (deliberately steer the market into the hard-to-reach regimes)
    // =============================

    /// @notice Deposits exactly the advertised senior capacity so the gates land on their boundary
    function aimed_depositExactlyMaxST(uint256 _actorSeed) external {
        address actor = stActors[bound(_actorSeed, 0, stActors.length - 1)];
        Snap memory s = _syncAndVerify("pre:aimedMaxST");
        if (s.ok) {
            uint256 maxAssets = toUint256(kernel.stMaxDeposit(actor));
            if (maxAssets == 0) {
                // No capacity: a one-unit deposit must be rejected by one of the gates
                _execStDeposit(actor, 1e12, s);
            } else {
                // Overflow guard only, the boundary case stays exact whenever capacity is below the cap
                _execStDeposit(actor, maxAssets > 1e27 ? 1e27 : maxAssets, s);
            }
            _syncAndVerify("post:aimedMaxST");
        }
    }

    /// @notice Applies the closed-form shared-rate drop that pushes coverage utilization to liquidation
    function aimed_loseUntilLiquidation() external {
        Snap memory s = _syncAndVerify("pre:aimedLiquidation");
        if (s.ok && s.stEff + s.jtEff > 0) {
            // Solve for the loss fraction f on both raw NAVs that lands coverage utilization on the
            // liquidation threshold L. With a shared feed both legs lose f, junior absorbs its own loss
            // plus coverage, so jtEff' = jtEff(1-f) - f*stEff and the exposure shrinks to (1-f)(stRaw+jtRaw).
            // Requiring exposure*minCov/jtEff' >= L and isolating f gives
            // f = (jtEff - E*C/L) / (stEff + jtEff - E*C/L) with E = stRaw + jtRaw and C = minCov
            uint256 ecl = (s.stRaw + s.jtRaw).mulDiv(s.minCov, s.covLiqUtil);
            if (s.jtEff <= ecl || s.covUtil >= s.covLiqUtil) {
                // Already at or past the threshold: realize it with a plain sync and count the regime
                ghost_syncCount += 0;
            } else {
                uint256 fWAD = (s.jtEff - ecl).mulDiv(WAD, s.stEff + s.jtEff - ecl, Math.Rounding.Ceil) + 0.01e18;
                if (fWAD > 0.97e18) fWAD = 0.97e18;
                int256 bpsDrop = int256(fWAD / 1e14) + 1;
                ghost_uncoveredLossSinceLastCheck = true;
                ghost_jtLossSinceLastCheck = true;
                ghost_ltVenueLossSinceLastCheck = true;
                applySTPnL(-bpsDrop);
            }
            _syncAndVerify("post:aimedLiquidation");
        }
    }

    /// @notice Applies a drawdown small enough for junior to fully cover, driving the fixed-term entry
    function aimed_coveredDrawdown(uint256 _lossBps) external {
        Snap memory s = _syncAndVerify("pre:aimedDrawdown");
        if (s.ok && s.stEff > 0 && s.jtEff > 0) {
            // A shared loss f stays fully covered while f*stEff <= jtEff(1-f), so the covered ceiling is
            // f < jtEff / (stEff + jtEff). Stay one percent under it and inside the three-percent op range
            uint256 fMaxBps = s.jtEff.mulDiv(10_000, s.stEff + s.jtEff);
            if (fMaxBps > 100) {
                // Uniform over one basis point to the covered ceiling capped at three percent
                uint256 cap = fMaxBps - 100 > 300 ? 300 : fMaxBps - 100;
                int256 bps = int256(bound(_lossBps, 1, cap));
                ghost_jtLossSinceLastCheck = true;
                applySTPnL(-bps);
            }
            _syncAndVerify("post:aimedDrawdown");
        }
    }

    /// @notice Flips the venue between clean adds and punitive slippage so premium actually stages
    function aimed_toggleVenueSlippage() external {
        ghost_venueSlippageArmed = !ghost_venueSlippageArmed;
        setVenueSlippageMode(ghost_venueSlippageArmed);
        _recordSuccess("toggleVenueSlippage");
        _syncAndVerify("post:toggleSlippage");
    }

    /// @notice Every actor of one tranche redeems its advertised maximum, chasing the empty-tranche edges
    function aimed_fullExit(uint256 _trancheSeed) external {
        // Uniform over the three tranches
        uint256 t = bound(_trancheSeed, 0, 2);
        Snap memory s = _syncAndVerify("pre:aimedFullExit");
        if (s.ok) {
            if (t == 0) {
                for (uint256 i; i < stActors.length; ++i) {
                    uint256 shares = seniorTranche.maxRedeem(stActors[i]);
                    if (shares != 0) {
                        s = _refreshSnap();
                        _execStRedeem(stActors[i], shares, s);
                    }
                }
            } else if (t == 1) {
                for (uint256 i; i < jtActors.length; ++i) {
                    uint256 shares = juniorTranche.maxRedeem(jtActors[i]);
                    if (shares != 0) {
                        s = _refreshSnap();
                        _execJtRedeem(jtActors[i], shares, s);
                    }
                }
            } else {
                for (uint256 i; i < ltActors.length; ++i) {
                    uint256 shares = liquidityTranche.maxRedeem(ltActors[i]);
                    if (shares != 0) {
                        s = _refreshSnap();
                        _execLtRedeem(ltActors[i], shares, s);
                    }
                }
            }
            if (seniorTranche.totalSupply() == 0 || juniorTranche.totalSupply() == 0 || liquidityTranche.totalSupply() == 0) {
                ghost_zeroSupplyStatesReached++;
            }
            _syncAndVerify("post:aimedFullExit");
        }
    }

    // =============================
    // Op executors (shared by the weighted and aimed ops)
    // =============================

    /// @dev Runs one senior deposit under an independently derived revert prediction
    function _execStDeposit(address _actor, uint256 _assets, Snap memory s) internal {
        Pred memory p;
        uint256 value = _quoteSTUnits(_assets);
        if (s.fixedTerm) {
            _expect(p, SEL_DISABLED_FT);
        } else {
            uint256 stRawAfter = _quoteSTUnits(s.stOwned + _assets);
            if (stRawAfter == s.stRaw || value == 0) {
                _expect(p, SEL_INVALID_POST_OP);
                _expect(p, SEL_ZERO_VALUE);
            }
            uint256 stEffAfter = s.stEff + (stRawAfter - s.stRaw);
            if (RoycoTestMath.covUtil(stRawAfter, s.jtRaw, JT_CO, s.minCov, s.jtEff) > WAD) _expect(p, SEL_COVERAGE);
            if (RoycoTestMath.liqUtil(stEffAfter, s.minLiq, s.ltRaw) > WAD) _expect(p, SEL_LIQUIDITY);
            if (RoycoTestMath.sharesFor(value, s.stEff, s.stSupply) == 0) _expect(p, SEL_ZERO_SHARES);
        }
        stJtVault.mintShares(_actor, _assets);
        vm.startPrank(_actor);
        stJtVault.approve(address(seniorTranche), _assets);
        try seniorTranche.deposit(toTrancheUnits(_assets), _actor) returns (uint256 gotShares) {
            _recordSuccess("stDeposit");
            ghost_transferredIn[address(stJtVault)] += _assets;
            _flag(gotShares == RoycoTestMath.sharesFor(value, s.stEff, s.stSupply), "stDeposit minted shares diverge from the floor mirror");
        } catch (bytes memory err) {
            _classify("stDeposit", err, p);
        }
        vm.stopPrank();
    }

    /// @dev Runs one senior redemption under an independently derived revert prediction
    function _execStRedeem(address _actor, uint256 _shares, Snap memory s) internal {
        Pred memory p;
        if (s.fixedTerm) {
            _expect(p, SEL_DISABLED_FT);
        } else if (s.stSupply == 0) {
            // Scaling a claim over a zero share supply divides by zero
            _expect(p, SEL_PANIC);
        } else {
            (uint256 stA, uint256 jtA, uint256 bonusNAV) = _mirrorSeniorRedeemClaims(s, _shares, s.stSupply);
            if (bonusNAV > 0) ghost_jtLossSinceLastCheck = true;
            uint256 rawAfterST = _quoteSTUnits(s.stOwned - stA);
            uint256 rawAfterJT = _quoteJTUnits(s.jtOwned - jtA);
            if (rawAfterST == s.stRaw && rawAfterJT == s.jtRaw) _expect(p, SEL_INVALID_POST_OP);
            if (_shares > seniorTranche.balanceOf(_actor)) _expect(p, SEL_ERC20_BALANCE);
        }
        uint256 outBefore = stJtVault.balanceOf(_actor);
        vm.prank(_actor);
        try seniorTranche.redeem(_shares, _actor, _actor) {
            _recordSuccess("stRedeem");
            ghost_transferredOut[address(stJtVault)] += stJtVault.balanceOf(_actor) - outBefore;
        } catch (bytes memory err) {
            _classify("stRedeem", err, p);
        }
    }

    /// @dev Runs one junior redemption under an independently derived revert prediction
    function _execJtRedeem(address _actor, uint256 _shares, Snap memory s) internal {
        Pred memory p;
        uint256 ilExpected = ghost_ilReplay;
        if (s.fixedTerm) {
            _expect(p, SEL_DISABLED_FT);
        } else if (s.jtSupply == 0) {
            _expect(p, SEL_PANIC);
        } else {
            // Junior claims decompose into a cross-claim on senior assets plus the self-backed remainder
            uint256 jtClaimOnST = _sat(s.jtEff, s.jtRaw);
            uint256 jtClaimOnJT = s.jtRaw - _sat(s.stEff, s.stRaw);
            uint256 stA = jtClaimOnST == 0 ? 0 : _quoteNAVToSTUnits(jtClaimOnST).mulDiv(_shares, s.jtSupply);
            uint256 jtA = jtClaimOnJT == 0 ? 0 : _quoteNAVToJTUnits(jtClaimOnJT).mulDiv(_shares, s.jtSupply);
            uint256 rawAfterST = _quoteSTUnits(s.stOwned - stA);
            uint256 rawAfterJT = _quoteJTUnits(s.jtOwned - jtA);
            uint256 totalRedeemed = (s.stRaw - rawAfterST) + (s.jtRaw - rawAfterJT);
            if (totalRedeemed == 0) _expect(p, SEL_INVALID_POST_OP);
            uint256 jtEffAfter = s.jtEff - totalRedeemed;
            if (RoycoTestMath.covUtil(rawAfterST, rawAfterJT, JT_CO, s.minCov, jtEffAfter) > WAD) _expect(p, SEL_COVERAGE);
            if (totalRedeemed != 0 && s.il != 0) ilExpected = s.il.mulDiv(jtEffAfter, s.jtEff);
            if (_shares > juniorTranche.balanceOf(_actor)) _expect(p, SEL_ERC20_BALANCE);
        }
        uint256 outBefore = stJtVault.balanceOf(_actor);
        vm.prank(_actor);
        try juniorTranche.redeem(_shares, _actor, _actor) {
            _recordSuccess("jtRedeem");
            ghost_transferredOut[address(stJtVault)] += stJtVault.balanceOf(_actor) - outBefore;
            // A junior exit realizes its slice of the coverage loss ledger pro rata
            if (ilExpected != ghost_ilReplay) {
                ghost_ilEvents.push(ILEvent(ILCause.JT_REDEEM_SCALE, ghost_ilReplay - ilExpected));
                ghost_ilReplay = ilExpected;
            }
            _flag(toUint256(accountant.getState().lastJTCoverageImpermanentLoss) == ilExpected, "jtRedeem coverage-loss scaling diverges from the floor mirror");
        } catch (bytes memory err) {
            _classify("jtRedeem", err, p);
        }
    }

    /// @dev Runs one in-kind liquidity redemption under an independently derived revert prediction
    function _execLtRedeem(address _actor, uint256 _shares, Snap memory s) internal {
        Pred memory p;
        if (s.fixedTerm) {
            _expect(p, SEL_DISABLED_FT);
        } else if (s.ltSupply == 0) {
            _expect(p, SEL_PANIC);
        } else {
            uint256 ltClaimUnits = s.ltRaw == 0 ? 0 : _quoteNAVToLTUnits(s.ltRaw);
            uint256 userLt = ltClaimUnits.mulDiv(_shares, s.ltSupply);
            uint256 ltRawAfter = _quoteLTUnits(s.ltOwned - userLt);
            if (ltRawAfter == s.ltRaw) _expect(p, SEL_INVALID_POST_OP);
            bool enforced = s.covUtil < s.covLiqUtil;
            if (enforced && RoycoTestMath.liqUtil(s.stEff, s.minLiq, ltRawAfter) > WAD) _expect(p, SEL_LIQUIDITY);
            if (_shares > liquidityTranche.balanceOf(_actor)) _expect(p, SEL_ERC20_BALANCE);
        }
        uint256 bptBefore = bpt.balanceOf(_actor);
        uint256 idleBefore = seniorTranche.balanceOf(_actor);
        vm.prank(_actor);
        try liquidityTranche.redeem(_shares, _actor, _actor) {
            _recordSuccess("ltRedeem");
            ghost_transferredOut[address(bpt)] += bpt.balanceOf(_actor) - bptBefore;
            ghost_idleSharesPaidToRedeemers += seniorTranche.balanceOf(_actor) - idleBefore;
        } catch (bytes memory err) {
            _classify("ltRedeem", err, p);
        }
    }

    /// @dev Runs one multi-asset liquidity deposit under a full mirror of the mock venue's pricing
    function _execLtDepositMultiAsset(address _actor, uint256 _stAssets, uint256 _quoteAssets, Snap memory s) internal {
        Pred memory p;
        if (s.fixedTerm && _stAssets > 0) {
            _expect(p, SEL_DISABLED_FT);
        } else {
            VenueAdd memory v = _mirrorVenueAdd(s, _stAssets, _quoteAssets);
            if (_stAssets > 0 && v.stSharesMinted == 0) _expect(p, SEL_ZERO_SHARES);
            if (v.valueAllocated == 0) {
                _expect(p, SEL_ZERO_VALUE);
                _expect(p, SEL_INVALID_POST_OP);
            }
            if (v.ltRawAfter <= s.ltRaw) _expect(p, SEL_INVALID_POST_OP);
            uint256 navAt = RoycoTestMath.ltEffNav(s.ltRaw, s.idle, s.stEff, s.stSupply);
            if (RoycoTestMath.sharesFor(v.valueAllocated, navAt, s.ltSupply) == 0) _expect(p, SEL_ZERO_SHARES);
            if (_stAssets > 0) {
                uint256 stRawAfter = _quoteSTUnits(s.stOwned + _stAssets);
                uint256 stEffAfter = s.stEff + (stRawAfter - s.stRaw);
                if (RoycoTestMath.covUtil(stRawAfter, s.jtRaw, JT_CO, s.minCov, s.jtEff) > WAD) _expect(p, SEL_COVERAGE);
                if (RoycoTestMath.liqUtil(stEffAfter, s.minLiq, v.ltRawAfter) > WAD) _expect(p, SEL_LIQUIDITY);
            }
        }
        stJtVault.mintShares(_actor, _stAssets);
        quoteToken.mint(_actor, _quoteAssets);
        vm.startPrank(_actor);
        stJtVault.approve(address(liquidityTranche), _stAssets);
        quoteToken.approve(address(liquidityTranche), _quoteAssets);
        try liquidityTranche.depositMultiAsset(_stAssets, _quoteAssets, 0, _actor) {
            _recordSuccess("ltDepositMultiAsset");
            ghost_transferredIn[address(stJtVault)] += _stAssets;
        } catch (bytes memory err) {
            _classify("ltDepositMultiAsset", err, p);
        }
        vm.stopPrank();
    }

    /// @dev Runs one multi-asset liquidity redemption under a full mirror of the proportional removal
    function _execLtRedeemMultiAsset(address _actor, uint256 _shares, Snap memory s) internal {
        Pred memory p;
        if (s.fixedTerm) {
            _expect(p, SEL_DISABLED_FT);
        } else if (s.ltSupply == 0 || s.stSupply == 0) {
            _expect(p, SEL_PANIC);
        } else {
            RemovalMirror memory r = _mirrorVenueRemoval(s, _shares);
            if (r.bonusNAV > 0) ghost_jtLossSinceLastCheck = true;
            bool deltaLtNegative = r.ltRawAfter < s.ltRaw;
            if (!deltaLtNegative && r.totalRedeemed == 0) _expect(p, SEL_INVALID_POST_OP);
            bool enforced = s.covUtil < s.covLiqUtil;
            uint256 stEffAfter = s.stEff - (r.totalRedeemed - r.bonusNAV);
            if (enforced && RoycoTestMath.liqUtil(stEffAfter, s.minLiq, r.ltRawAfter) > WAD) _expect(p, SEL_LIQUIDITY);
            if (_shares > liquidityTranche.balanceOf(_actor)) _expect(p, SEL_ERC20_BALANCE);
        }
        uint256 vaultSharesBefore = stJtVault.balanceOf(_actor);
        uint256 quoteBefore = quoteToken.balanceOf(_actor);
        uint256 idleLedgerBefore = kernel.getState().ltOwnedSeniorTrancheShares;
        vm.prank(_actor);
        try liquidityTranche.redeemMultiAsset(_shares, 0, 0, _actor, _actor) {
            _recordSuccess("ltRedeemMultiAsset");
            ghost_transferredOut[address(stJtVault)] += stJtVault.balanceOf(_actor) - vaultSharesBefore;
            ghost_transferredOut[address(quoteToken)] += quoteToken.balanceOf(_actor) - quoteBefore;
            // The redeemer's staged-premium slice is unwound on its behalf rather than handed over as shares
            ghost_idleSharesPaidToRedeemers += idleLedgerBefore - kernel.getState().ltOwnedSeniorTrancheShares;
        } catch (bytes memory err) {
            _classify("ltRedeemMultiAsset", err, p);
        }
    }

    // =============================
    // Venue mirrors (exact reproductions of the mock venue's pricing for gate prediction)
    // =============================

    /// @dev Everything the multi-asset deposit prediction needs about the venue add's outcome
    struct VenueAdd {
        uint256 stSharesMinted;
        uint256 bptOut;
        uint256 ltRawAfter;
        uint256 valueAllocated;
    }

    /// @dev Mirrors the unbalanced add: fair value at the vault's prices, the armed haircut, the oracle re-mark
    function _mirrorVenueAdd(Snap memory s, uint256 _stAssets, uint256 _quoteAssets) internal view returns (VenueAdd memory v) {
        uint256 rate = _mirrorSeniorRate(s.stEff, s.stSupply);
        v.stSharesMinted = _stAssets == 0 ? 0 : RoycoTestMath.sharesFor(_quoteSTUnits(_stAssets), s.stEff, s.stSupply);
        uint256[2] memory balances = balancerVault.getPoolBalances(address(bpt));
        uint256 stBal = balances[stPoolTokenIndex];
        uint256 qBal = balances[1 - stPoolTokenIndex];
        uint256 vaultQuotePrice = balancerVault.getTokenPriceWAD(address(quoteToken));
        uint256 valueIn = v.stSharesMinted.mulDiv(rate, WAD) + _quoteAssets.mulDiv(vaultQuotePrice, QUOTE_UNIT);
        uint256 poolValue = stBal.mulDiv(rate, WAD) + qBal.mulDiv(vaultQuotePrice, QUOTE_UNIT);
        uint256 bptSupply = bpt.totalSupply();
        v.bptOut = (bptSupply == 0 || poolValue == 0) ? valueIn : valueIn.mulDiv(bptSupply, poolValue);
        v.bptOut = (v.bptOut * (10_000 - (ghost_venueSlippageArmed ? VENUE_SLIPPAGE_MODE_FEE_BPS : 0))) / 10_000;
        // The oracle marks the post-add pool at its own quote price with the senior leg at the pinned rate
        uint256 oracleQuotePrice = bptOracle.getPriceWAD(address(quoteToken));
        uint256 tvlAfter = (stBal + v.stSharesMinted).mulDiv(rate, WAD) + (qBal + _quoteAssets).mulDiv(oracleQuotePrice, QUOTE_UNIT);
        uint256 supplyAfter = bptSupply + v.bptOut;
        v.ltRawAfter = supplyAfter == 0 ? 0 : (s.ltOwned + v.bptOut).mulDiv(tvlAfter, supplyAfter);
        v.valueAllocated = supplyAfter == 0 ? 0 : v.bptOut.mulDiv(tvlAfter, supplyAfter);
    }

    /// @dev Everything the multi-asset redemption prediction needs about the proportional removal's outcome
    struct RemovalMirror {
        uint256 ltRawAfter;
        uint256 totalRedeemed;
        uint256 bonusNAV;
    }

    /// @dev Mirrors the proportional removal, the senior unwind, and the exit bonus for gate prediction
    function _mirrorVenueRemoval(Snap memory s, uint256 _shares) internal view returns (RemovalMirror memory r) {
        uint256 ltClaimUnits = s.ltRaw == 0 ? 0 : _quoteNAVToLTUnits(s.ltRaw);
        uint256 userLt = ltClaimUnits.mulDiv(_shares, s.ltSupply);
        uint256 idleSlice = s.idle.mulDiv(_shares, s.ltSupply);
        uint256[2] memory balances = balancerVault.getPoolBalances(address(bpt));
        uint256 bptSupply = bpt.totalSupply();
        uint256 stOut = balances[stPoolTokenIndex].mulDiv(userLt, bptSupply);
        uint256 qOut = balances[1 - stPoolTokenIndex].mulDiv(userLt, bptSupply);
        {
            uint256 rate = _mirrorSeniorRate(s.stEff, s.stSupply);
            uint256 oracleQuotePrice = bptOracle.getPriceWAD(address(quoteToken));
            uint256 tvlAfter =
                (balances[stPoolTokenIndex] - stOut).mulDiv(rate, WAD) + (balances[1 - stPoolTokenIndex] - qOut).mulDiv(oracleQuotePrice, QUOTE_UNIT);
            uint256 supplyAfter = bptSupply - userLt;
            r.ltRawAfter = supplyAfter == 0 ? 0 : (s.ltOwned - userLt).mulDiv(tvlAfter, supplyAfter);
        }
        // The redeemer's senior shares come from the pool withdrawal plus its staged-premium slice
        uint256 sToRedeem = stOut + idleSlice;
        (uint256 stA, uint256 jtA, uint256 bonusNAV) = _mirrorSeniorRedeemClaims(s, sToRedeem, s.stSupply);
        r.bonusNAV = bonusNAV;
        uint256 rawAfterST = _quoteSTUnits(s.stOwned - stA);
        uint256 rawAfterJT = _quoteJTUnits(s.jtOwned - jtA);
        r.totalRedeemed = (s.stRaw - rawAfterST) + (s.jtRaw - rawAfterJT);
    }

    /// @dev Mirrors a senior redemption's asset claims (scaled slice plus any liquidation exit bonus)
    function _mirrorSeniorRedeemClaims(Snap memory s, uint256 _shares, uint256 _totalShares)
        internal
        view
        returns (uint256 stA, uint256 jtA, uint256 bonusNAV)
    {
        uint256 jtClaimOnST = _sat(s.jtEff, s.jtRaw);
        uint256 stClaimOnST = s.stRaw - jtClaimOnST;
        uint256 stClaimOnJT = _sat(s.stEff, s.stRaw);
        stA = stClaimOnST == 0 ? 0 : _quoteNAVToSTUnits(stClaimOnST).mulDiv(_shares, _totalShares);
        jtA = stClaimOnJT == 0 ? 0 : _quoteNAVToJTUnits(stClaimOnJT).mulDiv(_shares, _totalShares);
        if (s.covUtil >= s.covLiqUtil) {
            uint256 navSlice = s.stEff.mulDiv(_shares, _totalShares);
            bonusNAV = RoycoTestMath.selfLiqBonus(
                RoycoTestMath.SelfLiqBonusIn({
                    stRaw: s.stRaw,
                    jtRaw: s.jtRaw,
                    jtEff: s.jtEff,
                    jtCoinvested: JT_CO,
                    coverageUtilizationWAD: s.covUtil,
                    coverageLiquidationUtilizationWAD: s.covLiqUtil,
                    bonusWAD: s.bonusWAD,
                    userClaimNAV: navSlice,
                    stUserWeightedClaimNAV: _quoteSTUnits(stA) + (JT_CO ? _quoteJTUnits(jtA) : 0)
                })
            );
            uint256 bonusFromST = Math.min(bonusNAV, jtClaimOnST);
            if (bonusFromST != 0) stA += _quoteNAVToSTUnits(bonusFromST);
            if (bonusNAV - bonusFromST != 0) jtA += _quoteNAVToJTUnits(bonusNAV - bonusFromST);
        }
    }

    // =============================
    // The verified sync (runs before and after every op)
    // =============================

    /// @dev Pre-sync reads packaged for the verification pass
    struct SyncCtx {
        uint256 stRawNew;
        uint256 jtRawNew;
        uint256 stSupply0;
        uint256 jtSupply0;
        uint256 ltSupply0;
        uint256 idle0;
        uint256 poolSenior0;
        uint256 twJT;
        uint256 twLT;
        uint256 elapsedPrem;
        bool firstAccrual;
        bool wasBreached;
        MarketState state0;
        bool mirrorOk;
        RoycoTestMath.WaterfallOut w;
    }

    /**
     * @dev Syncs the market as the keeper and verifies the entire outcome against independent mirrors:
     *      the committed NAVs against the waterfall recomputation, the share mints against the carve-out
     *      floors, the staged-premium ledger against the pool's own balance movement, the accrual window
     *      against the pinned model constants, the committed pool mark against a manual re-pricing, and
     *      the three share prices against their high-water marks outside sanctioned loss events
     */
    function _syncAndVerify(string memory _label) internal returns (Snap memory s) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = accountant.getState();
        IRoycoDayKernel.RoycoDayKernelState memory k0 = kernel.getState();
        SyncCtx memory c;
        c.stSupply0 = seniorTranche.totalSupply();
        c.jtSupply0 = juniorTranche.totalSupply();
        c.ltSupply0 = liquidityTranche.totalSupply();
        c.idle0 = k0.ltOwnedSeniorTrancheShares;
        c.poolSenior0 = seniorTranche.balanceOf(address(balancerVault));
        c.state0 = a0.lastMarketState;
        c.wasBreached = RoycoTestMath.covUtil(
            toUint256(a0.lastSTRawNAV), toUint256(a0.lastJTRawNAV), JT_CO, a0.minCoverageWAD, toUint256(a0.lastJTEffectiveNAV)
        ) >= a0.coverageLiquidationUtilizationWAD;

        // Recompute the premium accrual window exactly as the accountant will, off the pinned model
        if (a0.lastYieldShareAccrualTimestamp == 0) {
            c.firstAccrual = true;
        } else {
            uint256 elapsedAcc = block.timestamp - uint256(a0.lastYieldShareAccrualTimestamp);
            c.twJT = uint256(a0.twJTYieldShareAccruedWAD) + Math.min(JT_PINNED_SHARE_WAD, a0.maxJTYieldShareWAD) * elapsedAcc;
            c.twLT = uint256(a0.twLTYieldShareAccruedWAD) + Math.min(LT_PINNED_SHARE_WAD, a0.maxLTYieldShareWAD) * elapsedAcc;
            c.elapsedPrem = block.timestamp - uint256(a0.lastPremiumPaymentTimestamp);
        }

        // The sync itself: it must always succeed while the oracle is healthy
        vm.prank(SYNC_OPERATOR);
        try kernel.syncTrancheAccounting() {
            ghost_syncCount++;
        } catch {
            _flag(false, string.concat(_label, ": syncTrancheAccounting reverted on a healthy market"));
            s.ok = false;
            return s;
        }

        // Quote the raw marks after the sync so the freshly initialized rate cache prices them exactly as
        // the sync did (the owned amounts themselves cannot move during a sync)
        c.stRawNew = _quoteSTUnits(toUint256(k0.stOwnedYieldBearingAssets));
        c.jtRawNew = _quoteJTUnits(toUint256(k0.jtOwnedYieldBearingAssets));

        // Recompute the full waterfall from the committed checkpoint and this block's fresh marks
        RoycoTestMath.WaterfallIn memory win = RoycoTestMath.WaterfallIn({
            stRawLast: toUint256(a0.lastSTRawNAV),
            jtRawLast: toUint256(a0.lastJTRawNAV),
            stEffLast: toUint256(a0.lastSTEffectiveNAV),
            jtEffLast: toUint256(a0.lastJTEffectiveNAV),
            jtCoverageILLast: toUint256(a0.lastJTCoverageImpermanentLoss),
            marketStateLast: c.state0 == MarketState.PERPETUAL ? RoycoTestMath.MarketState.PERPETUAL : RoycoTestMath.MarketState.FIXED_TERM,
            fixedTermEndLast: uint256(a0.fixedTermEndTimestamp),
            stRawDelta: int256(c.stRawNew) - int256(toUint256(a0.lastSTRawNAV)),
            jtRawDelta: int256(c.jtRawNew) - int256(toUint256(a0.lastJTRawNAV)),
            ltRawNew: toUint256(a0.lastLTRawNAV),
            jtTwYieldShareAccrual: c.twJT,
            ltTwYieldShareAccrual: c.twLT,
            elapsedSincePremiumPayment: c.elapsedPrem,
            jtInstYieldShareWAD: JT_PINNED_SHARE_WAD,
            ltInstYieldShareWAD: LT_PINNED_SHARE_WAD,
            maxJTYieldShareWAD: a0.maxJTYieldShareWAD,
            maxLTYieldShareWAD: a0.maxLTYieldShareWAD,
            stProtocolFeeWAD: a0.stProtocolFeeWAD,
            jtProtocolFeeWAD: a0.jtProtocolFeeWAD,
            jtYieldShareProtocolFeeWAD: a0.jtYieldShareProtocolFeeWAD,
            ltYieldShareProtocolFeeWAD: a0.ltYieldShareProtocolFeeWAD,
            nowTimestamp: block.timestamp,
            fixedTermDuration: a0.fixedTermDurationSeconds,
            minCoverageWAD: a0.minCoverageWAD,
            jtCoinvested: JT_CO,
            coverageLiquidationUtilizationWAD: a0.coverageLiquidationUtilizationWAD,
            effectiveDust: toUint256(a0.effectiveNAVDustTolerance),
            minLiquidityWAD: a0.minLiquidityWAD
        });
        try this.runWaterfallMirror(win) returns (RoycoTestMath.WaterfallOut memory w) {
            c.mirrorOk = true;
            c.w = w;
        } catch {
            _flag(false, string.concat(_label, ": independent waterfall recomputation reverted (conservation or premium bound broke)"));
        }

        s = _verifyPostSync(_label, a0, c);
    }

    /// @dev The post-sync half of the verification, split out to bound stack usage
    function _verifyPostSync(string memory _label, IRoycoDayAccountant.RoycoDayAccountantState memory a0, SyncCtx memory c) internal returns (Snap memory s) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a1 = accountant.getState();
        IRoycoDayKernel.RoycoDayKernelState memory k1 = kernel.getState();

        // Committed raw marks must echo the fresh quotes, and raw must equal effective in total
        _flag(
            toUint256(a1.lastSTRawNAV) == c.stRawNew && toUint256(a1.lastJTRawNAV) == c.jtRawNew,
            string.concat(_label, ": committed raw marks diverge from the fresh quotes")
        );
        _flag(
            c.stRawNew + c.jtRawNew == toUint256(a1.lastSTEffectiveNAV) + toUint256(a1.lastJTEffectiveNAV),
            string.concat(_label, ": raw and effective NAV totals diverge after the sync")
        );

        uint256 premiumShares;
        if (c.mirrorOk) {
            _flag(toUint256(a1.lastSTEffectiveNAV) == c.w.stEff, string.concat(_label, ": committed senior effective NAV diverges from the recomputation"));
            _flag(toUint256(a1.lastJTEffectiveNAV) == c.w.jtEff, string.concat(_label, ": committed junior effective NAV diverges from the recomputation"));
            _flag(
                toUint256(a1.lastJTCoverageImpermanentLoss) == c.w.jtCoverageIL,
                string.concat(_label, ": committed coverage loss diverges from the recomputation")
            );
            _flag(
                (a1.lastMarketState == MarketState.PERPETUAL) == (c.w.marketState == RoycoTestMath.MarketState.PERPETUAL),
                string.concat(_label, ": committed market state diverges from the recomputation")
            );
            _flag(uint256(a1.fixedTermEndTimestamp) == c.w.fixedTermEnd, string.concat(_label, ": committed fixed-term end diverges from the recomputation"));

            // Replay the coverage-loss ledger through its only four sanctioned movements
            _recordIlMovement(a0, c.w);
            _flag(
                ghost_ilReplay == toUint256(a1.lastJTCoverageImpermanentLoss),
                string.concat(_label, ": coverage-loss ledger replay diverges from the committed value")
            );

            // The senior supply may grow only by the premium and fee carve-outs, both floor-priced
            uint256 feeShares;
            (premiumShares, feeShares,) = RoycoTestMath.carveOut(c.w.stEff, c.w.ltLiquidityPremium, c.w.stProtocolFee, c.stSupply0);
            _flag(
                seniorTranche.totalSupply() == c.stSupply0 + premiumShares + feeShares,
                string.concat(_label, ": senior supply moved by something other than the premium and fee carve-outs")
            );
            ghost_premiumSharesMinted += premiumShares;
            uint256 jtFeeShares = c.w.jtProtocolFee == 0 ? 0 : RoycoTestMath.sharesFor(c.w.jtProtocolFee, c.w.jtEff - c.w.jtProtocolFee, c.jtSupply0);
            _flag(juniorTranche.totalSupply() == c.jtSupply0 + jtFeeShares, string.concat(_label, ": junior supply moved by something other than the fee mint"));

            // Premium accrual window: reset exactly when premiums pay, otherwise grow by the pinned model
            if (c.firstAccrual || c.w.premiumsPaid) {
                _flag(
                    a1.twJTYieldShareAccruedWAD == 0 && a1.twLTYieldShareAccruedWAD == 0 && uint256(a1.lastPremiumPaymentTimestamp) == block.timestamp,
                    string.concat(_label, ": premium accumulators failed to reset on a premium payment")
                );
                ghost_windowMaxJTShareWAD = a1.maxJTYieldShareWAD;
                ghost_windowMaxLTShareWAD = a1.maxLTYieldShareWAD;
            } else {
                _flag(
                    uint256(a1.twJTYieldShareAccruedWAD) == c.twJT && uint256(a1.twLTYieldShareAccruedWAD) == c.twLT,
                    string.concat(_label, ": accrued premium weight diverges from the pinned model accrual")
                );
                _flag(
                    a1.lastPremiumPaymentTimestamp == a0.lastPremiumPaymentTimestamp,
                    string.concat(_label, ": premium payment timestamp moved without a payment")
                );
            }
            if (c.elapsedPrem > 0) {
                _flag(
                    c.twJT <= ghost_windowMaxJTShareWAD * c.elapsedPrem && c.twLT <= ghost_windowMaxLTShareWAD * c.elapsedPrem,
                    string.concat(_label, ": accrued premium weight exceeds the configured cap over the window")
                );
            }
            if (IS_ZERO_LIQUIDITY_PROFILE) {
                _flag(c.w.ltLiquidityPremium == 0 && premiumShares == 0, string.concat(_label, ": zero-liquidity market accrued a liquidity premium"));
            }
        }
        _flag(uint256(a1.lastYieldShareAccrualTimestamp) == block.timestamp, string.concat(_label, ": accrual timestamp failed to advance to this block"));

        // Staged-premium conservation: the ledger moves only by the mint and the measured pool deployment
        uint256 deployed = seniorTranche.balanceOf(address(balancerVault)) - c.poolSenior0;
        ghost_premiumSharesReinvested += deployed;
        if (c.mirrorOk) {
            _flag(
                k1.ltOwnedSeniorTrancheShares == c.idle0 + premiumShares - deployed,
                string.concat(_label, ": staged premium ledger diverges from mint minus measured deployment")
            );
        }
        if (k1.ltOwnedSeniorTrancheShares > 0) ghost_stagedPremiumObserved++;

        // Solvency: every internal ledger is fully backed by the kernel's actual token balances
        _flag(
            stJtVault.balanceOf(address(kernel)) == toUint256(k1.stOwnedYieldBearingAssets) + toUint256(k1.jtOwnedYieldBearingAssets),
            string.concat(_label, ": kernel vault-share balance no longer backs the senior plus junior ledgers")
        );
        _flag(
            bpt.balanceOf(address(kernel)) == toUint256(k1.ltOwnedYieldBearingAssets),
            string.concat(_label, ": kernel pool-token balance no longer backs the liquidity ledger")
        );
        _flag(
            seniorTranche.balanceOf(address(kernel)) == k1.ltOwnedSeniorTrancheShares,
            string.concat(_label, ": kernel senior-share balance no longer backs the staged premium ledger")
        );
        _flag(quoteToken.balanceOf(address(kernel)) == 0, string.concat(_label, ": kernel retained quote tokens it should never hold"));

        // The committed pool mark must equal a manual re-pricing of the kernel's pool tokens and must
        // exclude the staged premium shares, which appear only in the effective value
        uint256 stEff1 = toUint256(a1.lastSTEffectiveNAV);
        uint256 stSupply1 = seniorTranche.totalSupply();
        uint256 ltRawMirror = _mirrorLtRawNAV(toUint256(k1.ltOwnedYieldBearingAssets), stEff1, stSupply1);
        _flag(toUint256(a1.lastLTRawNAV) == ltRawMirror, string.concat(_label, ": committed pool mark diverges from the manual re-pricing"));
        uint256 ltEffNavMirror = RoycoTestMath.ltEffNav(ltRawMirror, k1.ltOwnedSeniorTrancheShares, stEff1, stSupply1);
        _flag(
            toUint256(liquidityTranche.totalAssets().nav) == ltEffNavMirror,
            string.concat(_label, ": liquidity effective value is not the pool mark plus the staged premium slice")
        );

        _checkPriceMonotonicity(_label, a1, stSupply1, ltEffNavMirror);
        _trackRegimes(a1, c);
        s = _buildSnap(a1, k1, ltEffNavMirror);
    }

    /// @dev Appends this sync's coverage-loss movement to the event log and advances the replay value
    function _recordIlMovement(IRoycoDayAccountant.RoycoDayAccountantState memory a0, RoycoTestMath.WaterfallOut memory w) internal {
        uint256 ilBefore = toUint256(a0.lastJTCoverageImpermanentLoss);
        if (w.ilErased > 0) {
            // Erasure runs after any same-sync growth or recovery, so log that movement first
            uint256 preErase = w.jtCoverageIL + w.ilErased;
            if (preErase > ilBefore) ghost_ilEvents.push(ILEvent(ILCause.COVERAGE_APPLIED, preErase - ilBefore));
            else if (preErase < ilBefore) ghost_ilEvents.push(ILEvent(ILCause.RECOVERY, ilBefore - preErase));
            ghost_ilEvents.push(ILEvent(ILCause.ERASED, w.ilErased));
            ghost_ilReplay = w.jtCoverageIL;
        } else if (w.jtCoverageIL > ilBefore) {
            ghost_ilEvents.push(ILEvent(ILCause.COVERAGE_APPLIED, w.jtCoverageIL - ilBefore));
            ghost_ilReplay = ghost_ilReplay + (w.jtCoverageIL - ilBefore);
        } else if (w.jtCoverageIL < ilBefore) {
            ghost_ilEvents.push(ILEvent(ILCause.RECOVERY, ilBefore - w.jtCoverageIL));
            ghost_ilReplay = ghost_ilReplay - (ilBefore - w.jtCoverageIL);
        }
    }

    /// @dev Verifies the three share prices never fall outside a sanctioned loss event, then re-arms
    /// @dev A tranche whose supply hits zero starts a fresh price series, so its high-water resets there
    function _checkPriceMonotonicity(
        string memory _label,
        IRoycoDayAccountant.RoycoDayAccountantState memory a1,
        uint256 _stSupply,
        uint256 _ltEffNav
    )
        internal
    {
        uint256 jtEff1 = toUint256(a1.lastJTEffectiveNAV);
        if (_stSupply == 0) ghost_stPriceHighWater = 0;
        if (_stSupply > 0) {
            uint256 pSt = toUint256(a1.lastSTEffectiveNAV).mulDiv(WAD, _stSupply);
            uint256 dust = PRICE_FLOOR_DUST_NAV_WEI_DERIVED_BOUND.mulDiv(WAD, _stSupply) + 2;
            if (pSt + dust < ghost_stPriceHighWater) {
                _flag(ghost_uncoveredLossSinceLastCheck && jtEff1 == 0, string.concat(_label, ": senior share price fell without an uncovered loss"));
                if (jtEff1 == 0) ghost_uncoveredLossRealized++;
            }
            ghost_stPriceHighWater = pSt;
        }
        uint256 jtSupply1 = juniorTranche.totalSupply();
        if (jtSupply1 == 0) ghost_jtPriceHighWater = 0;
        if (jtSupply1 > 0) {
            uint256 pJt = jtEff1.mulDiv(WAD, jtSupply1);
            uint256 dust = PRICE_FLOOR_DUST_NAV_WEI_DERIVED_BOUND.mulDiv(WAD, jtSupply1) + 2;
            if (pJt + dust < ghost_jtPriceHighWater) {
                _flag(ghost_jtLossSinceLastCheck, string.concat(_label, ": junior share price fell without a junior loss event"));
            }
            ghost_jtPriceHighWater = pJt;
        }
        uint256 ltSupply1 = liquidityTranche.totalSupply();
        if (ltSupply1 == 0) ghost_ltPriceHighWater = 0;
        if (ltSupply1 > 0) {
            uint256 pLt = _ltEffNav.mulDiv(WAD, ltSupply1);
            uint256 dust = PRICE_FLOOR_DUST_NAV_WEI_DERIVED_BOUND.mulDiv(WAD, ltSupply1) + 2;
            if (pLt + dust < ghost_ltPriceHighWater) {
                _flag(
                    ghost_ltVenueLossSinceLastCheck || (ghost_uncoveredLossSinceLastCheck && jtEff1 == 0),
                    string.concat(_label, ": liquidity share price fell without a venue or uncovered loss event")
                );
            }
            ghost_ltPriceHighWater = pLt;
        }
        ghost_uncoveredLossSinceLastCheck = false;
        ghost_jtLossSinceLastCheck = false;
        ghost_ltVenueLossSinceLastCheck = false;
    }

    /// @dev Advances the regime counters off the observed state transition
    function _trackRegimes(IRoycoDayAccountant.RoycoDayAccountantState memory a1, SyncCtx memory c) internal {
        if (c.state0 == MarketState.PERPETUAL && a1.lastMarketState == MarketState.FIXED_TERM) ghost_enteredFixedTerm++;
        if (c.state0 == MarketState.FIXED_TERM && a1.lastMarketState == MarketState.PERPETUAL) ghost_exitedFixedTerm++;
        bool breachedNow = RoycoTestMath.covUtil(
            toUint256(a1.lastSTRawNAV), toUint256(a1.lastJTRawNAV), JT_CO, a1.minCoverageWAD, toUint256(a1.lastJTEffectiveNAV)
        ) >= a1.coverageLiquidationUtilizationWAD;
        if (!c.wasBreached && breachedNow) ghost_crossedLiquidationThreshold++;
    }

    /// @dev Packages the freshly committed state into the snapshot ops predict their gates from
    function _buildSnap(
        IRoycoDayAccountant.RoycoDayAccountantState memory a1,
        IRoycoDayKernel.RoycoDayKernelState memory k1,
        uint256
    )
        internal
        view
        returns (Snap memory s)
    {
        s.ok = true;
        s.fixedTerm = a1.lastMarketState == MarketState.FIXED_TERM;
        s.stRaw = toUint256(a1.lastSTRawNAV);
        s.jtRaw = toUint256(a1.lastJTRawNAV);
        s.ltRaw = toUint256(a1.lastLTRawNAV);
        s.stEff = toUint256(a1.lastSTEffectiveNAV);
        s.jtEff = toUint256(a1.lastJTEffectiveNAV);
        s.il = toUint256(a1.lastJTCoverageImpermanentLoss);
        s.covUtil = RoycoTestMath.covUtil(s.stRaw, s.jtRaw, JT_CO, a1.minCoverageWAD, s.jtEff);
        s.minCov = a1.minCoverageWAD;
        s.minLiq = a1.minLiquidityWAD;
        s.covLiqUtil = a1.coverageLiquidationUtilizationWAD;
        s.effDust = toUint256(a1.effectiveNAVDustTolerance);
        s.stSupply = seniorTranche.totalSupply();
        s.jtSupply = juniorTranche.totalSupply();
        s.ltSupply = liquidityTranche.totalSupply();
        s.stOwned = toUint256(k1.stOwnedYieldBearingAssets);
        s.jtOwned = toUint256(k1.jtOwnedYieldBearingAssets);
        s.ltOwned = toUint256(k1.ltOwnedYieldBearingAssets);
        s.idle = k1.ltOwnedSeniorTrancheShares;
        s.bonusWAD = k1.stSelfLiquidationBonusWAD;
    }

    /// @dev Rebuilds the snapshot from committed state without re-syncing (same block, nothing moved the feeds)
    function _refreshSnap() internal view returns (Snap memory s) {
        s = _buildSnap(accountant.getState(), kernel.getState(), 0);
    }

    // =============================
    // External self-call so a mirror revert is caught instead of aborting the op
    // =============================

    /// @notice Runs the independent waterfall recomputation, callable only by the handler itself
    function runWaterfallMirror(RoycoTestMath.WaterfallIn memory _in) external view returns (RoycoTestMath.WaterfallOut memory) {
        require(msg.sender == address(this), "only self");
        return RoycoTestMath.waterfall(_in);
    }

    // =============================
    // Core-invariant view for the invariant contract
    // =============================

    /// @notice Recomputes the always-true identities from live state, returning the first breach found
    function coreInvariantBreach() external view returns (string memory) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        IRoycoDayKernel.RoycoDayKernelState memory k = kernel.getState();
        if (toUint256(a.lastSTRawNAV) + toUint256(a.lastJTRawNAV) != toUint256(a.lastSTEffectiveNAV) + toUint256(a.lastJTEffectiveNAV)) {
            return "raw and effective NAV totals diverge";
        }
        if (stJtVault.balanceOf(address(kernel)) != toUint256(k.stOwnedYieldBearingAssets) + toUint256(k.jtOwnedYieldBearingAssets)) {
            return "kernel vault-share balance does not back the senior plus junior ledgers";
        }
        uint256 netIn = ghost_transferredIn[address(stJtVault)] - ghost_transferredOut[address(stJtVault)];
        if (stJtVault.balanceOf(address(kernel)) != netIn) return "kernel vault-share balance diverges from the transfer ledger";
        if (bpt.balanceOf(address(kernel)) != toUint256(k.ltOwnedYieldBearingAssets)) return "kernel pool-token balance does not back the liquidity ledger";
        if (seniorTranche.balanceOf(address(kernel)) != k.ltOwnedSeniorTrancheShares) return "kernel senior-share balance does not back the staged premium";
        if (ghost_premiumSharesMinted != k.ltOwnedSeniorTrancheShares + ghost_premiumSharesReinvested + ghost_idleSharesPaidToRedeemers) {
            return "staged premium ledger does not reconcile minted, deployed, and paid-out shares";
        }
        return "";
    }

    /// @notice The number of recorded coverage-loss ledger movements
    function ilEventCount() external view returns (uint256) {
        return ghost_ilEvents.length;
    }

    // =============================
    // Internal helpers
    // =============================

    /// @dev Mints pool tokens to an account at the pool's current value per token, backed by a real quote leg
    function _mintFairValueBpt(address _to, uint256 _quoteLeg) internal returns (uint256 bptAmt) {
        uint256 valueWAD = _quoteLeg.mulDiv(bptOracle.getPriceWAD(address(quoteToken)), QUOTE_UNIT);
        uint256 tvl = bptOracle.computeTVL();
        bptAmt = tvl == 0 ? valueWAD : valueWAD.mulDiv(bpt.totalSupply(), tvl);
        if (bptAmt == 0) bptAmt = 1;
        quoteToken.mint(_to, _quoteLeg);
        vm.startPrank(_to);
        quoteToken.approve(address(balancerVault), _quoteLeg);
        uint256[2] memory legs;
        legs[1 - stPoolTokenIndex] = _quoteLeg;
        balancerVault.mintPoolTokensTo(address(bpt), _to, bptAmt, legs);
        vm.stopPrank();
    }

    /// @dev Re-prices the kernel's pool tokens by hand: pool balances at the pinned senior rate and the oracle quote price
    function _mirrorLtRawNAV(uint256 _ltOwned, uint256 _stEff, uint256 _stSupply) internal view returns (uint256) {
        uint256 supply = bpt.totalSupply();
        if (supply == 0) return 0;
        uint256 rate = _mirrorSeniorRate(_stEff, _stSupply);
        uint256[2] memory balances = balancerVault.getPoolBalances(address(bpt));
        uint256 tvl =
            balances[stPoolTokenIndex].mulDiv(rate, WAD) + balances[1 - stPoolTokenIndex].mulDiv(bptOracle.getPriceWAD(address(quoteToken)), QUOTE_UNIT);
        return _ltOwned.mulDiv(tvl, supply);
    }

    /// @dev The senior share rate the pool prices with: effective value per share, floored to one wei
    function _mirrorSeniorRate(uint256 _stEff, uint256 _stSupply) internal pure returns (uint256) {
        if (_stSupply == 0) return 1;
        uint256 r = _stEff.mulDiv(WAD, _stSupply);
        return r == 0 ? 1 : r;
    }

    function _quoteSTUnits(uint256 _units) internal view returns (uint256) {
        return toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(_units)));
    }

    function _quoteJTUnits(uint256 _units) internal view returns (uint256) {
        return toUint256(kernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(_units)));
    }

    function _quoteLTUnits(uint256 _units) internal view returns (uint256) {
        return toUint256(kernel.ltConvertTrancheUnitsToNAVUnits(toTrancheUnits(_units)));
    }

    function _quoteNAVToSTUnits(uint256 _nav) internal view returns (uint256) {
        return toUint256(kernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(_nav)));
    }

    function _quoteNAVToJTUnits(uint256 _nav) internal view returns (uint256) {
        return toUint256(kernel.jtConvertNAVUnitsToTrancheUnits(toNAVUnits(_nav)));
    }

    function _quoteNAVToLTUnits(uint256 _nav) internal view returns (uint256) {
        return toUint256(kernel.ltConvertNAVUnitsToTrancheUnits(toNAVUnits(_nav)));
    }

    /// @dev Saturating subtraction
    function _sat(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return _a > _b ? _a - _b : 0;
    }

    /// @dev Adds one selector to the op's allowed revert set
    function _expect(Pred memory _p, bytes4 _sel) internal pure {
        _p.sels[_p.n++] = _sel;
    }

    /// @dev Checks an observed revert against the op's allowed set, recording a violation on a miss
    function _classify(string memory _op, bytes memory _err, Pred memory _p) internal {
        bytes4 sel = _err.length >= 4 ? bytes4(_err) : bytes4(0);
        for (uint256 i; i < _p.n; ++i) {
            if (_p.sels[i] == sel) {
                ghost_opPredictedReverts[keccak256(bytes(_op))]++;
                return;
            }
        }
        _flag(false, string.concat(_op, ": unpredicted revert with selector ", vm.toString(bytes32(sel))));
    }

    /// @dev Records a successful op execution
    function _recordSuccess(string memory _op) internal {
        ghost_opSuccesses[keccak256(bytes(_op))]++;
    }

    /// @dev Records a violation without reverting, so the sequence that produced it is preserved
    function _flag(bool _condition, string memory _what) internal {
        if (!_condition) {
            ghost_violationCount++;
            if (bytes(ghost_violation).length == 0) ghost_violation = _what;
        }
    }
}
