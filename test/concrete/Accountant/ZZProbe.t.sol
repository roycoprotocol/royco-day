// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

contract ZZProbe is AccountantTestBase {
    function setUp() public {
        _deploy(_defaultParams());
    }

    function _p(string memory tag, NAV_UNIT prod, uint256 rtm) internal {
        emit log_named_uint(string.concat(tag, " PROD"), toUint256(prod));
        emit log_named_uint(string.concat(tag, " RTM "), rtm);
    }

    function test_probe() public {
        // 1 crossClaim
        SyncedAccountingState memory st = _bareState(1000e18, 200e18, 100e18, 980e18, 220e18, 0.1e18, 0.05e18);
        _p("crossClaim", accountant.maxJTWithdrawal(st), RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 220e18, 0.1e18, 0, 0));

        // 2a earlyOut boundary
        st = _bareState(300e18, 100e18, 0, 300e18, 40e18 + 2, 0.1e18, 0);
        _p("eo_a", accountant.maxJTWithdrawal(st), RoycoTestMath.maxJTWithdrawal(300e18, 100e18, 40e18 + 2, 0.1e18, 0, 0));
        // 2b one wei above
        st = _bareState(300e18, 100e18, 0, 300e18, 40e18 + 3, 0.1e18, 0);
        _p("eo_b", accountant.maxJTWithdrawal(st), RoycoTestMath.maxJTWithdrawal(300e18, 100e18, 40e18 + 3, 0.1e18, 0, 0));
        // 2c zero-claims
        st = _bareState(0, 8e18, 0, 8e18, 8e18, 0.1e18, 0);
        _p("eo_c", accountant.maxJTWithdrawal(st), RoycoTestMath.maxJTWithdrawal(0, 8e18, 8e18, 0.1e18, 0, 0));

        // 3 CeilRequiredFudge
        _seedSymmetric(1000e18 + 7, 200e18, 100e18);
        _p(
            "ceilFudge",
            accountant.maxJTWithdrawal(_checkpointState()),
            RoycoTestMath.maxJTWithdrawal(1000e18 + 7, 200e18, 200e18, 0.1e18, 0, 0)
        );

        // 4 flatMarket (fresh deploy)
        _deploy(_defaultParams());
        st = _bareState(1000e18, 200e18, 100e18, 1000e18, 200e18, 0.1e18, DEFAULT_MIN_LIQUIDITY_WAD);
        _p("flat", accountant.maxJTWithdrawal(st), RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 200e18, 0.1e18, 0, 0));

        // 5 dustFold (dust 3,7)
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory pp = _defaultParams();
        pp.stNAVDustTolerance = toNAVUnits(uint256(3));
        pp.jtNAVDustTolerance = toNAVUnits(uint256(7));
        _deploy(pp);
        st = _bareState(1000e18, 200e18, 0, 1000e18, 200e18, 0.1e18, 0);
        _p("dust", accountant.maxJTWithdrawal(st), RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 200e18, 0.1e18, 3, 7));

        // 6 FudgeExact
        _deploy(_defaultParams());
        _seedFlatWithLT(SEED_LT_RAW);
        _p("fudgeExact", accountant.maxJTWithdrawal(_checkpointState()), RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 200e18, 0.1e18, 0, 0));

        // 7 CrossClaimGateBoundary
        _deploy(_defaultParams());
        _seedState(1000e18, 200e18, 980e18, 220e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory cp = _checkpointState();
        emit log_named_uint("ccGate stRaw", toUint256(cp.stRawNAV));
        emit log_named_uint("ccGate jtRaw", toUint256(cp.jtRawNAV));
        emit log_named_uint("ccGate jtEff", toUint256(cp.jtEffectiveNAV));
        emit log_named_uint("ccGate PROD", toUint256(accountant.maxJTWithdrawal(cp)));
    }
}
