// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
    IdenticalAssets_ST_JT_ChainlinkOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol";
import { toTrancheUnits } from "../../../src/libraries/Units.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_OraclePoisonThroughFlow
 * @notice Closes the always-running (mock, no-RPC) hole where a poisoned price feed / BPT oracle was asserted
 *         ONLY against the direct quoter view (Test_AdminAndOracleGates), never driven through a real deposit,
 *         redemption, or sync. Oracle liveness IS market liveness: a poisoned feed must brick every synced
 *         operation, not just the isolated view. This drives the poison through the production flows.
 * @dev The market's ST/JT price backbone is the shared Chainlink-shaped base->NAV feed; poisoning it makes the
 *      quoter revert on the op-start cache warm, so every deposit/redeem/sync reverts with the quoter's own
 *      selector. The BPT oracle backs the LT raw-NAV commit inside every sync, so poisoning it bricks the sync.
 */
contract Test_OraclePoisonThroughFlow is DayMarketTestBase {
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    uint256 internal stUnit;
    uint256 internal quoteUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
        // Seed a healthy market (JT + ST + auto-seeded LT depth) so every flow under test is otherwise reachable.
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
    }

    // ---------------------------------------------------------------------
    // helpers: attempt each real flow, expecting a specific revert
    // ---------------------------------------------------------------------

    function _fundST(address _actor, uint256 _shares) internal {
        stJtVault.mintShares(_actor, _shares);
        vm.prank(_actor);
        stJtVault.approve(address(seniorTranche), _shares);
    }

    function _fundJT(address _actor, uint256 _shares) internal {
        stJtVault.mintShares(_actor, _shares);
        vm.prank(_actor);
        stJtVault.approve(address(juniorTranche), _shares);
    }

    /// @dev Asserts that ST deposit, JT deposit, ST redeem, JT redeem, and a bare sync all revert with `_err`.
    ///      Uses the role-holding ST_PROVIDER/JT_PROVIDER so auth passes and the op reaches the oracle gate.
    function _assertAllSTJTFlowsRevert(bytes4 _err) internal {
        _fundST(ST_PROVIDER, stUnit);
        vm.prank(ST_PROVIDER);
        vm.expectRevert(_err);
        seniorTranche.deposit(toTrancheUnits(stUnit), ST_PROVIDER);

        _fundJT(JT_PROVIDER, stUnit);
        vm.prank(JT_PROVIDER);
        vm.expectRevert(_err);
        juniorTranche.deposit(toTrancheUnits(stUnit), JT_PROVIDER);

        uint256 stShares = seniorTranche.balanceOf(ST_PROVIDER) / 10;
        vm.prank(ST_PROVIDER);
        vm.expectRevert(_err);
        seniorTranche.redeem(stShares, ST_PROVIDER, ST_PROVIDER);

        uint256 jtShares = juniorTranche.balanceOf(JT_PROVIDER) / 10;
        vm.prank(JT_PROVIDER);
        vm.expectRevert(_err);
        juniorTranche.redeem(jtShares, JT_PROVIDER, JT_PROVIDER);

        vm.prank(SYNC_OPERATOR);
        vm.expectRevert(_err);
        kernel.syncTrancheAccounting();
    }

    /// @dev A clean deposit + sync succeed, proving the market recovers once the poison clears.
    function _assertFlowsRecover() internal {
        setOracleMode(ORACLE_MODE_NONE);
        _fundST(ST_PROVIDER, stUnit);
        vm.prank(ST_PROVIDER);
        seniorTranche.deposit(toTrancheUnits(stUnit), ST_PROVIDER); // no revert
        _sync(); // no revert
    }

    // ---------------------------------------------------------------------
    // ST/JT price-feed poison, driven through every synced flow
    // ---------------------------------------------------------------------

    function test_StaleFeed_bricksEverySTJTFlow_thenRecovers() public {
        setOracleMode(ORACLE_MODE_STALE);
        _assertAllSTJTFlowsRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.STALE_PRICE.selector);
        _assertFlowsRecover();
    }

    function test_ZeroAnswerFeed_bricksEverySTJTFlow_thenRecovers() public {
        setOracleMode(ORACLE_MODE_ZERO);
        _assertAllSTJTFlowsRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_PRICE.selector);
        _assertFlowsRecover();
    }

    function test_NegativeAnswerFeed_bricksEverySTJTFlow_thenRecovers() public {
        setOracleMode(ORACLE_MODE_NEGATIVE);
        _assertAllSTJTFlowsRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_PRICE.selector);
        _assertFlowsRecover();
    }

    function test_RevertingFeed_bricksEverySTJTFlow_thenRecovers() public {
        setOracleMode(ORACLE_MODE_REVERT);
        _assertAllSTJTFlowsRevert(MockAggregatorV3.ORACLE_REVERT_MODE.selector);
        _assertFlowsRecover();
    }

    // ---------------------------------------------------------------------
    // BPT-oracle poison bricks the sync (the LT raw-NAV commit reads computeTVL)
    // ---------------------------------------------------------------------

    function test_RevertingBPTOracle_bricksSync_thenRecovers() public {
        bptOracle.setRevertMode(true);
        vm.prank(SYNC_OPERATOR);
        vm.expectRevert(MockBPTOracle.ORACLE_REVERT_MODE.selector);
        kernel.syncTrancheAccounting();

        // Recover: disarm the oracle and confirm the sync lands again.
        bptOracle.setRevertMode(false);
        _sync();
    }
}
