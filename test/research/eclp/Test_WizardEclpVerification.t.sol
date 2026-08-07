// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { IVaultMock } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/test/IVaultMock.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { PoolRoleAccounts, TokenConfig } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { GyroECLPMath } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/lib/GyroECLPMath.sol";
import { CREATE3 } from "../../../lib/balancer-v3-monorepo/pkg/solidity-utils/contracts/solmate/CREATE3.sol";
import { ERC20TestToken } from "../../../lib/balancer-v3-monorepo/pkg/solidity-utils/contracts/test/ERC20TestToken.sol";
import { BasicAuthorizerMock } from "../../../lib/balancer-v3-monorepo/pkg/vault/contracts/test/BasicAuthorizerMock.sol";
import { ProtocolFeeControllerMock } from "../../../lib/balancer-v3-monorepo/pkg/vault/contracts/test/ProtocolFeeControllerMock.sol";
import { VaultAdminMock } from "../../../lib/balancer-v3-monorepo/pkg/vault/contracts/test/VaultAdminMock.sol";
import { VaultExtensionMock } from "../../../lib/balancer-v3-monorepo/pkg/vault/contracts/test/VaultExtensionMock.sol";
import { VaultMock } from "../../../lib/balancer-v3-monorepo/pkg/vault/contracts/test/VaultMock.sol";
import { Test } from "../../../lib/forge-std/src/Test.sol";
import { console2 } from "../../../lib/forge-std/src/console2.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { EclpTestRouter } from "./Test_ECLPExitLiquidityPoolEconomics.t.sol";

/**
 * @title Test_WizardEclpVerification
 * @notice DEPLOY_MARKET_SPEC.md §12.1 leg 3: replay of the /deploy-market wizard's TS-side ECLP outputs
 *         (derived params + balancer-maths exit quotes) against the OFFICIAL Balancer V3 Solidity vendored
 *         in this repo. Fixture: test/research/eclp/fixtures/wizard-eclp-verification.json, emitted by
 *         royco-rwa-frontend/scripts/generate-eclp-verification-fixtures.ts (5 golden C4/live-market
 *         configs + 60 seeded wizard-domain configs; per config several TVLs; per pool exact-in
 *         ST -> quote swaps of 0.1%..40% of TVL).
 *
 * @dev FAITHFULNESS OF THE SWAP PATH. This is NOT a re-implementation of the vault's fee/rounding
 *      sequence — every quote goes through the real deployed stack:
 *        - the REAL Vault bytecode: VaultMock extends the production Vault, deployed via CREATE3 with the
 *          production VaultExtension/VaultAdmin graph and production-realistic minimums (min trade 1e6,
 *          min wrap 1e3), the exact recipe of ECLPExitLiquidityBase in this directory;
 *        - a REAL GyroECLPPool per fixture pool, deployed through the vendored GyroECLPPoolFactory with
 *          the TS-derived 38-dec params (so the pool CONSTRUCTOR itself re-runs validateParams +
 *          validateDerivedParamsLimits on the wizard's exact bytes), fee = the wizard's swapFeeWad;
 *        - swaps executed via Vault.swap(EXACT_IN) through the same minimal unlock-router the economics
 *          suite uses. The vault applies the static swap fee where production applies it: fee =
 *          amountGivenScaled18.mulUp(swapFeePercentage) subtracted from the given amount BEFORE
 *          GyroECLPPool.onSwap runs the invariant math (Vault.sol _swap, EXACT_IN branch), and the
 *          resulting amountOutScaled18 is descaled round-down to raw.
 *      Both tokens are 18-decimals and registered STANDARD (rate 1e18), matching the TS pool state
 *      (scalingFactors [1,1], tokenRates [1e18,1e18]) — raw == scaled on both sides, so the comparison is
 *      wei-for-wei with no decimal plumbing in between. Aggregate/protocol fees are 0 in both stacks (TS
 *      aggregateSwapFee = 0, ProtocolFeeControllerMock(0,0)); they would not change amountOut either way.
 *      The TS side (vendored balancer-maths Vault.swap) mirrors this sequence line for line — mulUp fee on
 *      the scaled given amount, GyroECLPMath.calcOutGivenIn with invariant {x: inv + 2e, y: inv}, round-down
 *      descale — so the assertion is EXACT equality; any wei difference is a reported finding.
 *
 *      Run: FOUNDRY_PROFILE=research forge test --match-path 'test/research/eclp/Test_WizardEclpVerification.t.sol' -vv
 */
contract Test_WizardEclpVerification is Test {
    string internal constant FIXTURE = "test/research/eclp/fixtures/wizard-eclp-verification.json";

    IVaultMock internal vault;
    EclpTestRouter internal router;
    GyroECLPPoolFactory internal factory;
    ERC20TestToken internal st;
    ERC20TestToken internal quoteToken;

    // Per config (parallel arrays from the fixture).
    string[] internal labels;
    int256[] internal alpha_;
    int256[] internal beta_;
    int256[] internal c_;
    int256[] internal s_;
    int256[] internal lambda_;
    uint256[] internal swapFeeWad_;
    int256[] internal tauAlphaX_;
    int256[] internal tauAlphaY_;
    int256[] internal tauBetaX_;
    int256[] internal tauBetaY_;
    int256[] internal u_;
    int256[] internal v_;
    int256[] internal w_;
    int256[] internal z_;
    int256[] internal dSq_;

    // Per (config, tvl) pool.
    uint256[] internal poolConfigIndex_;
    uint256[] internal poolTvlUsd_;
    uint256[] internal poolBalance0_;
    uint256[] internal poolBalance1_;

    // Per swap.
    uint256[] internal swapPoolIndex_;
    uint256[] internal swapAmountIn_;
    uint256[] internal swapAmountOut_;

    function setUp() public {
        // Real Balancer V3 vault stack, the exact ECLPExitLiquidityBase recipe.
        BasicAuthorizerMock authorizer = new BasicAuthorizerMock();
        address predicted = CREATE3.getDeployed(bytes32(0));
        VaultAdminMock vaultAdmin = new VaultAdminMock(IVault(payable(predicted)), 90 days, 30 days, 1e6, 1e3);
        VaultExtensionMock vaultExtension = new VaultExtensionMock(IVault(payable(predicted)), vaultAdmin);
        ProtocolFeeControllerMock feeController = new ProtocolFeeControllerMock(IVaultMock(predicted), 0, 0);
        CREATE3.deploy(bytes32(0), abi.encodePacked(type(VaultMock).creationCode, abi.encode(vaultExtension, authorizer, feeController)), 0);
        vault = IVaultMock(predicted);
        router = new EclpTestRouter(IVault(predicted));
        factory = new GyroECLPPoolFactory(IVault(predicted), 365 days, "wizard-eclp-verification", "wizard-eclp-verification");

        // ST must be token0 (alpha/beta price ST in quote); mine the address ordering.
        st = new ERC20TestToken("Senior Tranche Share", "ST", 18);
        for (uint256 i = 0; i < 64; ++i) {
            quoteToken = new ERC20TestToken("Quote Stable", "QUSD", 18);
            if (address(st) < address(quoteToken)) break;
        }
        require(address(st) < address(quoteToken), "setUp: could not mine ST < quote address ordering");

        st.mint(address(this), 1e32);
        quoteToken.mint(address(this), 1e32);
        st.approve(address(router), type(uint256).max);
        quoteToken.approve(address(router), type(uint256).max);

        string memory json = vm.readFile(FIXTURE);
        labels = vm.parseJsonStringArray(json, ".label");
        alpha_ = vm.parseJsonIntArray(json, ".alpha");
        beta_ = vm.parseJsonIntArray(json, ".beta");
        c_ = vm.parseJsonIntArray(json, ".c");
        s_ = vm.parseJsonIntArray(json, ".s");
        lambda_ = vm.parseJsonIntArray(json, ".lambda");
        swapFeeWad_ = vm.parseJsonUintArray(json, ".swapFeeWad");
        tauAlphaX_ = vm.parseJsonIntArray(json, ".tauAlphaX");
        tauAlphaY_ = vm.parseJsonIntArray(json, ".tauAlphaY");
        tauBetaX_ = vm.parseJsonIntArray(json, ".tauBetaX");
        tauBetaY_ = vm.parseJsonIntArray(json, ".tauBetaY");
        u_ = vm.parseJsonIntArray(json, ".u");
        v_ = vm.parseJsonIntArray(json, ".v");
        w_ = vm.parseJsonIntArray(json, ".w");
        z_ = vm.parseJsonIntArray(json, ".z");
        dSq_ = vm.parseJsonIntArray(json, ".dSq");
        poolConfigIndex_ = vm.parseJsonUintArray(json, ".poolConfigIndex");
        poolTvlUsd_ = vm.parseJsonUintArray(json, ".poolTvlUsd");
        poolBalance0_ = vm.parseJsonUintArray(json, ".poolBalance0");
        poolBalance1_ = vm.parseJsonUintArray(json, ".poolBalance1");
        swapPoolIndex_ = vm.parseJsonUintArray(json, ".swapPoolIndex");
        swapAmountIn_ = vm.parseJsonUintArray(json, ".swapAmountIn");
        swapAmountOut_ = vm.parseJsonUintArray(json, ".swapAmountOut");

        require(labels.length == alpha_.length && labels.length == dSq_.length, "fixture: config arrays disagree");
        require(poolConfigIndex_.length == poolBalance0_.length, "fixture: pool arrays disagree");
        require(swapPoolIndex_.length == swapAmountOut_.length, "fixture: swap arrays disagree");
    }

    function _params(uint256 i) internal view returns (IGyroECLPPool.EclpParams memory) {
        return IGyroECLPPool.EclpParams({ alpha: alpha_[i], beta: beta_[i], c: c_[i], s: s_[i], lambda: lambda_[i] });
    }

    function _derived(uint256 i) internal view returns (IGyroECLPPool.DerivedEclpParams memory) {
        return IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({ x: tauAlphaX_[i], y: tauAlphaY_[i] }),
            tauBeta: IGyroECLPPool.Vector2({ x: tauBetaX_[i], y: tauBetaY_[i] }),
            u: u_[i],
            v: v_[i],
            w: w_[i],
            z: z_[i],
            dSq: dSq_[i]
        });
    }

    /// External wrapper so validation failures are caught and reported per config instead of aborting.
    function extValidate(uint256 i) external view {
        GyroECLPMath.validateParams(_params(i));
        GyroECLPMath.validateDerivedParamsLimits(_params(i), _derived(i));
    }

    /// (i) Every wizard config must pass Balancer's own on-chain validation with the TS-derived params.
    function test_ValidateParamsAndDerivedParams_AllConfigs() public {
        uint256 fails;
        for (uint256 i = 0; i < labels.length; ++i) {
            try this.extValidate(i) {
                // pass
            } catch (bytes memory reason) {
                fails++;
                console2.log("VALIDATION-FAIL config", i, labels[i]);
                console2.logBytes(reason);
            }
        }
        console2.log("validateParams+validateDerivedParamsLimits: configs", labels.length, "failures", fails);
        assertEq(fails, 0, "every wizard-accepted config must pass Balancer's on-chain validation");
    }

    function _tokens() internal view returns (IERC20[] memory t) {
        t = new IERC20[](2);
        t[0] = IERC20(address(st));
        t[1] = IERC20(address(quoteToken));
    }

    function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory amts) {
        amts = new uint256[](2);
        amts[0] = a;
        amts[1] = b;
    }

    /// Deploy + seed the real pool for fixture pool index `pi`. The factory create runs the
    /// GyroECLPPool constructor, which re-validates the wizard's exact param bytes on-chain.
    function _createFixturePool(uint256 pi) internal returns (address pool) {
        TokenConfig[] memory cfg = vault.buildTokenConfig(_tokens()); // both STANDARD, rate 1e18
        PoolRoleAccounts memory roleAccounts;
        uint256 ci = poolConfigIndex_[pi];
        pool = factory.create(
            labels[ci],
            "WIZ-ECLP",
            cfg,
            _params(ci),
            _derived(ci),
            roleAccounts,
            swapFeeWad_[ci],
            address(0),
            false,
            false,
            keccak256(abi.encode("wizard-eclp-verification", pi))
        );
        router.initialize(pool, address(this), _tokens(), _two(poolBalance0_[pi], poolBalance1_[pi]));
    }

    /// Replay fixture swap `si` against `pool` on a state snapshot; true iff Solidity == TS exactly.
    function _replaySwap(address pool, uint256 si) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        uint256 got = router.swapExactIn(pool, address(this), IERC20(address(st)), IERC20(address(quoteToken)), swapAmountIn_[si], 0);
        ok = got == swapAmountOut_[si];
        if (!ok) {
            uint256 pi = swapPoolIndex_[si];
            console2.log("QUOTE-MISMATCH config", poolConfigIndex_[pi], labels[poolConfigIndex_[pi]]);
            console2.log("  pool", pi, "tvlUsd", poolTvlUsd_[pi]);
            console2.log("  amountIn", swapAmountIn_[si]);
            console2.log("  ts  amountOut", swapAmountOut_[si]);
            console2.log("  sol amountOut", got);
        }
        vm.revertToState(snap);
    }

    /// (ii) Every TS quote must be reproduced EXACTLY by the real vault + real GyroECLPPool.
    function test_SwapQuotes_MatchSolidityExactly() public {
        vm.pauseGasMetering();
        uint256 fails;
        uint256 si = 0; // swaps are emitted grouped by pool index, ascending
        for (uint256 pi = 0; pi < poolConfigIndex_.length; ++pi) {
            address pool = _createFixturePool(pi);
            for (; si < swapPoolIndex_.length && swapPoolIndex_[si] == pi; ++si) {
                if (!_replaySwap(pool, si)) fails++;
            }
        }
        console2.log("swap quotes asserted", si, "mismatches", fails);
        assertEq(si, swapPoolIndex_.length, "every fixture swap must have been replayed");
        assertEq(fails, 0, "TS balancer-maths amountOut must equal the real Solidity amountOut to the wei");
    }
}
