// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";
import { MarketFuzzTestBase } from "../../utils/MarketFuzzTestBase.sol";

contract ZZTemp_Probe is MarketFuzzTestBase {
    function test_probe() public {
        uint256 _stSeed = 10000000000000000;
        uint256 _jtSeed = 3332;
        uint256 st = bound(_stSeed, 1e18, 1e27);
        uint256 jt = bound(_jtSeed, st / 2, 2 * st);
        _seedFlatMarket(st, jt, 0);

        uint256 reportedMax = juniorTranche.maxRedeem(JT_PROVIDER);
        uint256 rtm = RoycoTestMath.maxJTWithdrawal(st, jt, jt, 0.2e18, 1, 1);

        uint256 exposure = st + jt;
        uint256 requiredJT = Math.mulDiv(exposure, 0.2e18, WAD, Math.Rounding.Ceil);
        uint256 surplus = jt - (requiredJT + 4);
        uint256 y = Math.mulDiv(surplus, WAD, WAD - 0.2e18, Math.Rounding.Floor);

        uint256 k = (5 - (st + jt) % 5) % 5;
        uint256 oldFormula = (4 * jt - st - k - 20) / 4;

        emit log_named_uint("st", st);
        emit log_named_uint("jt", jt);
        emit log_named_uint("exposure", exposure);
        emit log_named_uint("exposure mod 5", exposure % 5);
        emit log_named_uint("requiredJT", requiredJT);
        emit log_named_uint("surplus", surplus);
        emit log_named_uint("y (closed form)", y);
        emit log_named_uint("oldFormula", oldFormula);
        emit log_named_uint("rtm (mirror)", rtm);
        emit log_named_uint("reportedMax (prod)", reportedMax);
    }
}
