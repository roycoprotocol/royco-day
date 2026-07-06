// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { RoycoDayAccountant } from "../../../src/accountant/RoycoDayAccountant.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockKernel, MockYDM, UninitializedERC1967Proxy } from "../../accountant/RoycoDayAccountant.t.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";

/**
 * @title AccountantUnitHarness
 * @notice Shared mock-kernel accountant harness for the carve-out, max-inversion, and self-liquidation unit
 *         vectors, mirroring the deploy and seeding surface of test/accountant/RoycoDayAccountant.t.sol
 *         without inheriting its test functions
 * @dev MockKernel, MockYDM, and the uninitialized proxy are imported from the accountant suite (import, not copy).
 *      Only the helpers these unit files need are mirrored: the default init params, the deploy path, a symmetric
 *      same-block seed, a bare state builder for the max* closed-form views, and the committed-checkpoint
 *      marshaller whose utilizations are recomputed through the independently validated RoycoTestMath formulas
 */
abstract contract AccountantUnitHarness is Test {
    // Default init params, identical to the accountant suite defaults so derivations carry over
    uint64 internal constant DEFAULT_MIN_COVERAGE_WAD = 0.1e18;
    uint256 internal constant DEFAULT_LIQUIDATION_UTILIZATION_WAD = 1.1e18;
    uint64 internal constant DEFAULT_MIN_LIQUIDITY_WAD = 0.05e18;
    uint64 internal constant DEFAULT_MAX_JT_YIELD_SHARE_WAD = 0.2e18;
    uint64 internal constant DEFAULT_MAX_LT_YIELD_SHARE_WAD = 0.1e18;
    uint24 internal constant DEFAULT_FIXED_TERM_DURATION_SECONDS = 604_800;
    uint64 internal constant DEFAULT_PROTOCOL_FEE_WAD = 0.1e18;

    RoycoDayAccountant internal accountant;
    MockKernel internal kernel;
    MockYDM internal jtYDM;
    MockYDM internal ltYDM;
    AccessManager internal authority;

    /*//////////////////////////////////////////////////////////////////////
                            DEPLOY HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /// @dev Default init params with null YDM slots that _deploy fills with fresh mocks
    function _defaultParams() internal pure returns (IRoycoDayAccountant.RoycoDayAccountantInitParams memory p) {
        p.minCoverageWAD = DEFAULT_MIN_COVERAGE_WAD;
        p.coverageLiquidationUtilizationWAD = DEFAULT_LIQUIDATION_UTILIZATION_WAD;
        p.minLiquidityWAD = DEFAULT_MIN_LIQUIDITY_WAD;
        p.jtYDM = address(0);
        p.jtYDMInitializationData = "";
        p.ltYDM = address(0);
        p.ltYDMInitializationData = "";
        p.maxJTYieldShareWAD = DEFAULT_MAX_JT_YIELD_SHARE_WAD;
        p.maxLTYieldShareWAD = DEFAULT_MAX_LT_YIELD_SHARE_WAD;
        p.fixedTermDurationSeconds = DEFAULT_FIXED_TERM_DURATION_SECONDS;
        p.stNAVDustTolerance = ZERO_NAV_UNITS;
        p.jtNAVDustTolerance = ZERO_NAV_UNITS;
        p.stProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        p.jtProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        p.jtYieldShareProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        p.ltYieldShareProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
    }

    /// @dev Deploys a fresh kernel, authority, implementation, proxy, and mock YDMs, then initializes the accountant
    function _deploy(bool _jtCoinvested, IRoycoDayAccountant.RoycoDayAccountantInitParams memory _params) internal returns (RoycoDayAccountant acct) {
        kernel = new MockKernel();
        authority = new AccessManager(address(this));
        RoycoDayAccountant implementation = new RoycoDayAccountant(address(kernel), _jtCoinvested);
        acct = RoycoDayAccountant(address(new UninitializedERC1967Proxy(address(implementation))));
        kernel.setAccountant(address(acct));
        if (_params.jtYDM == address(0)) _params.jtYDM = address(new MockYDM());
        if (_params.ltYDM == address(0)) _params.ltYDM = address(new MockYDM());
        jtYDM = MockYDM(_params.jtYDM);
        ltYDM = MockYDM(_params.ltYDM);
        acct.initialize(_params, address(authority));
        accountant = acct;
    }

    /*//////////////////////////////////////////////////////////////////////
                            STATE HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Seeds a symmetric committed checkpoint (stEff == stRaw, jtEff == jtRaw, IL 0, PERPETUAL) through legal
     *      kernel post-op deposits in the current block, then commits the liquidity tranche raw NAV
     */
    function _seedSymmetric(uint256 _stRaw, uint256 _jtRaw, uint256 _ltRaw) internal {
        if (_stRaw > 0) kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(_stRaw), ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
        if (_jtRaw > 0) kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(_stRaw), toNAVUnits(_jtRaw), ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
        kernel.doCommit(toNAVUnits(_ltRaw));

        // Self-verify the landed checkpoint so misuse is loud
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTRawNAV), _stRaw, "seed: stRaw");
        assertEq(toUint256(s.lastJTRawNAV), _jtRaw, "seed: jtRaw");
        assertEq(toUint256(s.lastSTEffectiveNAV), _stRaw, "seed: stEff");
        assertEq(toUint256(s.lastJTEffectiveNAV), _jtRaw, "seed: jtEff");
        assertEq(toUint256(s.lastLTRawNAV), _ltRaw, "seed: ltRaw");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "seed: market state");
    }

    /**
     * @dev Marshals the committed checkpoint into the synced accounting state the kernel would pass to the max*
     *      views, with both utilizations recomputed through the independent RoycoTestMath formulas
     */
    function _checkpointState() internal view returns (SyncedAccountingState memory st) {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        st.marketState = s.lastMarketState;
        st.stRawNAV = s.lastSTRawNAV;
        st.jtRawNAV = s.lastJTRawNAV;
        st.ltRawNAV = s.lastLTRawNAV;
        st.stEffectiveNAV = s.lastSTEffectiveNAV;
        st.jtEffectiveNAV = s.lastJTEffectiveNAV;
        st.jtCoverageImpermanentLoss = s.lastJTCoverageImpermanentLoss;
        st.coverageUtilizationWAD = RoycoTestMath.covUtil(
            toUint256(s.lastSTRawNAV), toUint256(s.lastJTRawNAV), accountant.JT_COINVESTED(), s.minCoverageWAD, toUint256(s.lastJTEffectiveNAV)
        );
        st.liquidityUtilizationWAD = RoycoTestMath.liqUtil(toUint256(s.lastSTEffectiveNAV), s.minLiquidityWAD, toUint256(s.lastLTRawNAV));
        st.fixedTermEndTimestamp = s.fixedTermEndTimestamp;
        st.minCoverageWAD = s.minCoverageWAD;
        st.jtCoinvested = accountant.JT_COINVESTED();
        st.coverageLiquidationUtilizationWAD = s.coverageLiquidationUtilizationWAD;
        st.minLiquidityWAD = s.minLiquidityWAD;
    }

    /**
     * @dev Builds a bare synced accounting state for direct max* closed-form probing. Only the fields the max*
     *      views read are populated, and the liquidation threshold defaults to the uint256 maximum so the
     *      maxLTWithdrawal liquidation shortcut stays un-triggered unless a test arms it
     */
    function _bareState(
        uint256 _stRaw,
        uint256 _jtRaw,
        uint256 _ltRaw,
        uint256 _stEff,
        uint256 _jtEff,
        bool _coinvested,
        uint256 _minCoverageWAD,
        uint256 _minLiquidityWAD
    )
        internal
        pure
        returns (SyncedAccountingState memory st)
    {
        st.stRawNAV = toNAVUnits(_stRaw);
        st.jtRawNAV = toNAVUnits(_jtRaw);
        st.ltRawNAV = toNAVUnits(_ltRaw);
        st.stEffectiveNAV = toNAVUnits(_stEff);
        st.jtEffectiveNAV = toNAVUnits(_jtEff);
        st.jtCoinvested = _coinvested;
        st.minCoverageWAD = _minCoverageWAD;
        st.minLiquidityWAD = _minLiquidityWAD;
        st.coverageLiquidationUtilizationWAD = type(uint256).max;
    }
}
