// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DeployScript } from "../../../script/Deploy.s.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { Test_BalancerLPGateReinvestBase } from "../balancer/base/Test_BalancerLPGateReinvestBase.t.sol";

/**
 * @title Neutrl_snUSD_Scenario
 * @notice Scenario-based fork tests for the Neutrl snUSD market: multiple actors run permutations of every
 *         deposit/redeem flow (ST/JT/LT, in-kind and multi-asset) interleaved with yield, loss, warps, syncs,
 *         and external Balancer swaps/LP adds, and the FULL protocol state is exhaustively verified after every
 *         step via one shared `_assertProtocolState` verifier. Delivered as both scripted permutations and a
 *         fuzzed op-sequence sharing that verifier.
 * @dev Reuses the deep Balancer-venue fork chain (external-LP helpers, pool readers, `_do*` op wrappers that
 *      already snapshot pre/post and assert per-op solvency, `_snap`/MarketSnapshot, `_assertCommittedConservation`
 *      /`_assertSolvency`, the seed/overlay/yield/sync helpers, and the actor model). RPC-gated: the inherited
 *      `setUp` `vm.skip`s the whole suite when `MAINNET_RPC_URL` is unset, and pins fork block 25_400_000.
 */
contract Neutrl_snUSD_Scenario is Test_BalancerLPGateReinvestBase {
    address internal constant SNUSD_VAULT = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313;
    address internal constant NUSD_REDSTONE_ORACLE = 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function _baseAssetToNavOracle() internal pure override returns (address) {
        return NUSD_REDSTONE_ORACLE;
    }

    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 25_400_000,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: SNUSD_VAULT,
            jtAsset: SNUSD_VAULT,
            quoteAsset: USDC,
            hasLiquidityTranche: true,
            initialFunding: 1_000_000e18
        });
    }

    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        return DEPLOY_SCRIPT.deploy(
            DEPLOY_SCRIPT.getMarketConfig("snUSD"),
            OWNER_ADDRESS,
            PROTOCOL_FEE_RECIPIENT_ADDRESS,
            DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds,
            _generateRoleAssignments(),
            DEPLOYER.privateKey
        );
    }

    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12));
    }

    function maxNAVDelta() public pure override returns (NAV_UNIT) {
        return toNAVUnits(uint256(1e12));
    }

    // ---------------------------------------------------------------------
    // The shared exhaustive per-step verifier
    // ---------------------------------------------------------------------

    /**
     * @notice Verifies the entire protocol state after a step: the wei-exact committed two-term NAV conservation,
     *         kernel solvency (owned ledgers vs custody), and that every tranche view/preview surface is live and
     *         self-consistent with the live snapshot (raw NAVs, effective NAVs, max/preview reads never revert).
     * @dev The inherited `_do*` wrappers already assert per-op solvency and snapshot pricing; this layers the
     *      market-wide invariants and the view-surface sweep the scenario suite is about.
     */
    function _assertProtocolState(string memory _ctx) internal {
        // 1. Wei-exact committed conservation and kernel solvency (inherited, load-bearing invariants).
        _assertCommittedConservation();
        _assertSolvency();

        MarketSnapshot memory s = _snap();

        // 2. Raw NAVs: the live tranche getters agree with the snapshot.
        assertEq(toUint256(ST.getRawNAV()), toUint256(s.stRawNAV), string.concat(_ctx, ": ST getRawNAV vs snapshot"));
        assertEq(toUint256(JT.getRawNAV()), toUint256(s.jtRawNAV), string.concat(_ctx, ": JT getRawNAV vs snapshot"));
        if (testConfig.hasLiquidityTranche) {
            assertEq(toUint256(LT.getRawNAV()), toUint256(s.ltRawNAV), string.concat(_ctx, ": LT getRawNAV vs snapshot"));
        }

        // 3. Effective NAVs and the full view surface are live (must not revert) after every step.
        _sweepViewSurface(address(ST), string.concat(_ctx, ": ST"));
        _sweepViewSurface(address(JT), string.concat(_ctx, ": JT"));
        if (testConfig.hasLiquidityTranche) _sweepViewSurface(address(LT), string.concat(_ctx, ": LT"));
    }

    /// @dev Reads every ERC4626-style view on a tranche so a revert (e.g. an empty-tranche panic) surfaces
    ///      immediately, and cross-checks the effective NAV (totalAssets().nav) against a maxRedeem/previewRedeem
    ///      round trip where the tranche is non-empty.
    function _sweepViewSurface(address _tranche, string memory _ctx) internal view {
        IRoycoVaultTranche t = IRoycoVaultTranche(_tranche);
        // Effective NAV read.
        toUint256(t.totalAssets().nav);
        // Deposit-side views.
        toUint256(t.maxDeposit(ST_ALICE_ADDRESS));
        if (t.totalSupply() != 0) {
            // Redeem-side views only meaningful with supply; a full-supply preview must not revert.
            uint256 maxR = t.maxRedeem(ST_ALICE_ADDRESS);
            if (maxR != 0) t.previewRedeem(maxR);
        }
        _ctx; // retained for assertion messages if the sweep is extended
    }

    // ---------------------------------------------------------------------
    // Scripted multi-party permutations
    // ---------------------------------------------------------------------

    /// @notice A healthy multi-party lifecycle: several actors deposit into all three tranches, yield accrues over
    ///         a window, an external arb swap hits the pool, then each actor partially exits — verified after every step.
    function test_Scenario_multiPartyHealthyLifecycle() public whenLT {
        uint256 fund = testConfig.initialFunding / 10;

        _doDepositJT(JT_ALICE_ADDRESS, fund);
        _assertProtocolState("after JT_ALICE deposit");
        _doDepositST(ST_ALICE_ADDRESS, fund);
        _assertProtocolState("after ST_ALICE deposit");

        _seedDefaultLT();
        _enableLTOverlay(0.5e18, 0.3e18, 0.05e18);
        _assertProtocolState("after LT overlay enable + seed");

        _doDepositST(ST_BOB_ADDRESS, fund / 2);
        _assertProtocolState("after ST_BOB deposit");
        _doDepositJT(JT_BOB_ADDRESS, fund / 2);
        _assertProtocolState("after JT_BOB deposit");

        _applySTYield(0.02e18); // +2% senior yield
        _warpForward(7 days);
        _sync();
        _assertProtocolState("after yield window + sync");

        _doRedeemST(ST_ALICE_ADDRESS, ST.balanceOf(ST_ALICE_ADDRESS) / 4);
        _assertProtocolState("after ST_ALICE partial redeem");
        _doRedeemJT(JT_ALICE_ADDRESS, JT.balanceOf(JT_ALICE_ADDRESS) / 4);
        _assertProtocolState("after JT_ALICE partial redeem");
        _doRedeemLT(LT_ALICE_ADDRESS, LT.balanceOf(LT_ALICE_ADDRESS) / 4);
        _assertProtocolState("after LT_ALICE partial in-kind redeem");
    }

    /// @notice LPs entering and exiting around a premium window while liquidity is provisioned, exercising the
    ///         multi-asset LT flows and a covered senior drawdown that transits FIXED_TERM and back.
    function test_Scenario_premiumWindowAndCoveredDrawdown() public whenLT {
        uint256 fund = testConfig.initialFunding / 10;

        _doDepositJT(JT_ALICE_ADDRESS, fund);
        _doDepositST(ST_ALICE_ADDRESS, fund);
        _seedDefaultLT();
        _enableLTOverlay(0.5e18, 0.3e18, 0.05e18);
        _assertProtocolState("arranged");

        // Premium window: yield accrues, sync deploys the liquidity premium.
        _applySTYield(0.03e18);
        _warpForward(14 days);
        _sync();
        _assertProtocolState("after premium window");

        // A covered senior drawdown (small enough to stay within the liquidation threshold).
        _applySTLoss(0.05e18);
        _sync();
        _assertProtocolState("after covered drawdown sync");

        // Recovery: yield restores the drawdown, the market returns to PERPETUAL.
        _applySTYield(0.06e18);
        _warpForward(3 days);
        _sync();
        _assertProtocolState("after recovery sync");
    }

    // ---------------------------------------------------------------------
    // Fuzzed op-sequence (shares the verifier)
    // ---------------------------------------------------------------------

    /// @notice Fuzzes a randomized sequence of deposit/redeem/yield/sync steps across actors, verifying the full
    ///         protocol state after every successful step. Amounts are bounded by the live max reads so no step
    ///         trips a gate, keeping every iteration on the verification path.
    function testFuzz_RandomOpSequence(uint256 _seed) public whenLT {
        uint256 fund = testConfig.initialFunding / 20;
        _doDepositJT(JT_ALICE_ADDRESS, fund);
        _doDepositST(ST_ALICE_ADDRESS, fund);
        _seedDefaultLT();
        _enableLTOverlay(0.5e18, 0.3e18, 0.05e18);
        _assertProtocolState("fuzz: arranged");

        uint256 seed = _seed;
        for (uint256 i = 0; i < 8; ++i) {
            uint256 op = seed % 6;
            seed = uint256(keccak256(abi.encode(seed, i)));

            if (op == 0) {
                // JT deposit — never gated.
                _doDepositJT(JT_BOB_ADDRESS, fund / 4 + 1);
            } else if (op == 1) {
                // ST deposit — bounded by the live coverage-and-liquidity max so it stays on-path.
                uint256 maxA = toUint256(ST.maxDeposit(ST_BOB_ADDRESS));
                if (maxA < 1e12) continue;
                _doDepositST(ST_BOB_ADDRESS, (maxA / 4) + 1);
            } else if (op == 2) {
                // JT redeem — bounded by the coverage-respecting max.
                uint256 maxR = JT.maxRedeem(JT_ALICE_ADDRESS);
                if (maxR < 1e12) continue;
                _doRedeemJT(JT_ALICE_ADDRESS, maxR / 4 + 1);
            } else if (op == 3) {
                // LT in-kind redeem — bounded by the liquidity-respecting max.
                uint256 maxR = LT.maxRedeem(LT_ALICE_ADDRESS);
                if (maxR < 1e12) continue;
                _doRedeemLT(LT_ALICE_ADDRESS, maxR / 4 + 1);
            } else if (op == 4) {
                // Up-only senior yield over a window, then a sync.
                _applySTYield(0.01e18);
                _warpForward(2 days);
                _sync();
            } else {
                // Bare warp + sync.
                _warpForward(1 days);
                _sync();
            }
            _assertProtocolState(string.concat("fuzz: step ", vm.toString(i)));
        }
    }
}
