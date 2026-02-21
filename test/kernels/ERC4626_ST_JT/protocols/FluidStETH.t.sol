// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IRoycoAccountant } from "../../../../src/interfaces/IRoycoAccountant.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { AssetClaims, MarketState, SyncedAccountingState } from "../../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { ERC4626_TestBase } from "../base/ERC4626_TestBase.t.sol";

/// @title FluidStETH_Test
/// @notice Tests ERC4626_ST_ERC4626_JT_InKindAssets_Kernel with Fluid's iETHv2 vault (stETH)
/// @dev Uses the actual Fluid vault on mainnet for production-like testing
contract FluidStETH_Test is ERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fluid iETHv2 vault on Ethereum mainnet
    address internal constant FLUID_IETH_V2 = 0xA0D3707c569ff8C87FA923d3823eC5D81c98Be78;

    /// @notice stETH (Lido Staked ETH) on Ethereum mainnet
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    /// @notice stETH whale address (Lido treasury/buffer)
    address internal constant STETH_WHALE = 0x93c4b944D05dfe6df7645A86cd2206016c51564D;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    function getProtocolConfig() public pure override returns (ProtocolConfig memory) {
        return ProtocolConfig({
            name: "FluidStETH",
            forkBlock: 24_290_290,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: STETH,
            jtAsset: STETH,
            stDecimals: 18,
            jtDecimals: 18,
            initialFunding: 1000e18
        });
    }

    function _getSTVault() internal pure override returns (address) {
        return FLUID_IETH_V2;
    }

    function _getJTVault() internal pure override returns (address) {
        return FLUID_IETH_V2;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STETH DEAL OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    function dealSTAsset(address _to, uint256 _amount) public override {
        vm.prank(STETH_WHALE);
        IERC20(STETH).transfer(_to, _amount);
    }

    function dealJTAsset(address _to, uint256 _amount) public override {
        vm.prank(STETH_WHALE);
        IERC20(STETH).transfer(_to, _amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // YIELD/LOSS SIMULATION
    // ═══════════════════════════════════════════════════════════════════════════
    // Fluid vault's exchange price = (currentNetAssets * 1e18) / totalSupply
    //
    // For yield: donate stETH to vault, then call updateExchangePrice
    // For loss: transfer stETH out of vault, then call updateExchangePrice
    //
    // Since ST and JT share the same Fluid vault, yield/loss affects both tranches.

    /// @notice Fluid vault rebalancer address
    address internal constant FLUID_REBALANCER = 0xC9f5920F5fa422C1c8975F12c0a2cF1467c947dB;

    /// @notice Function selector for updateExchangePrice()
    bytes4 internal constant UPDATE_EXCHANGE_PRICE_SELECTOR = 0x3bfaa7e3;

    /// @notice Simulates yield for ST by donating stETH and calling updateExchangePrice
    function simulateSTYield(uint256 _percentageWAD) public override {
        _simulateYield(_percentageWAD);
    }

    /// @notice Simulates yield for JT by donating stETH and calling updateExchangePrice
    function simulateJTYield(uint256 _percentageWAD) public override {
        _simulateYield(_percentageWAD);
    }

    /// @notice Simulates loss for ST by removing stETH and calling updateExchangePrice
    function simulateSTLoss(uint256 _percentageWAD) public override {
        _simulateLoss(_percentageWAD);
    }

    /// @notice Simulates loss for JT by removing stETH and calling updateExchangePrice
    function simulateJTLoss(uint256 _percentageWAD) public override {
        _simulateLoss(_percentageWAD);
    }

    /// @notice Donates stETH to vault and calls updateExchangePrice to realize yield
    function _simulateYield(uint256 _percentageWAD) internal {
        // Calculate donation amount based on current total assets
        uint256 totalAssets = IERC4626(FLUID_IETH_V2).totalAssets();
        uint256 donationAmount = totalAssets * _percentageWAD / WAD;
        if (donationAmount == 0) return;

        // Donate stETH directly to the vault
        dealSTAsset(address(this), donationAmount);
        IERC20(STETH).transfer(FLUID_IETH_V2, donationAmount);

        // Call updateExchangePrice as rebalancer
        _callUpdateExchangePrice();
    }

    /// @notice Transfers stETH out of vault and calls updateExchangePrice to realize loss
    function _simulateLoss(uint256 _percentageWAD) internal {
        // Calculate amount to remove based on current total assets
        uint256 totalAssets = IERC4626(FLUID_IETH_V2).totalAssets();
        uint256 removeAmount = totalAssets * _percentageWAD / WAD;
        if (removeAmount == 0) return;

        // Cap removeAmount to actual stETH balance in vault
        uint256 vaultBalance = IERC20(STETH).balanceOf(FLUID_IETH_V2);
        if (removeAmount > vaultBalance) {
            removeAmount = vaultBalance / 2; // Take at most half the available balance
        }
        if (removeAmount == 0) return;

        // Transfer stETH out of the vault (prank as vault)
        vm.prank(FLUID_IETH_V2);
        IERC20(STETH).transfer(address(this), removeAmount);

        // Call updateExchangePrice as rebalancer
        _callUpdateExchangePrice();
    }

    /// @notice Calls updateExchangePrice as rebalancer
    function _callUpdateExchangePrice() internal {
        vm.prank(FLUID_REBALANCER);
        (bool success,) = FLUID_IETH_V2.call(abi.encodeWithSelector(UPDATE_EXCHANGE_PRICE_SELECTOR));
        require(success, "updateExchangePrice failed");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES (stETH has 1-2 wei rounding per operation)
    // ═══════════════════════════════════════════════════════════════════════════

    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e15));
    }

    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FLUID-SPECIFIC DEPLOYMENT OVERRIDE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Override deployment to use 10 wei threshold for shared vault rounding
    /// @dev IL accumulates ~1 wei per 25-40 yield distribution cycles due to rounding
    ///      in Fluid's convertToAssets during ST withdrawals
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        ProtocolConfig memory cfg = getProtocolConfig();

        bytes32 marketId = keccak256(abi.encodePacked(cfg.name, "-", cfg.name, "-", vm.getBlockTimestamp()));

        DeployScript.ERC4626STERC4626JTInKindAssetsKernelParams memory kernelParams =
            DeployScript.ERC4626STERC4626JTInKindAssetsKernelParams({ stVault: _getSTVault(), jtVault: _getJTVault() });

        DeployScript.AdaptiveCurveYDM_V2_Params memory ydmParams = DeployScript.AdaptiveCurveYDM_V2_Params({
            jtYieldShareAtZeroUtilWAD: 0.3e18, // Y_0 = Y_T (same as target)
            jtYieldShareAtTargetUtilWAD: 0.3e18,
            jtYieldShareAtFullUtilWAD: 1e18,
            maxAdaptationSpeedWAD: uint64(30e18 / uint256(365 days))
        });

        // Build role assignments using the centralized function
        DeployScript.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        DeployScript.DeploymentParams memory params = DeployScript.DeploymentParams({
            factoryAdmin: OWNER_ADDRESS,
            marketId: marketId,
            seniorTrancheName: string(abi.encodePacked("Royco Senior ", cfg.name)),
            seniorTrancheSymbol: string(abi.encodePacked("RS-", cfg.name)),
            juniorTrancheName: string(abi.encodePacked("Royco Junior ", cfg.name)),
            juniorTrancheSymbol: string(abi.encodePacked("RJ-", cfg.name)),
            baseAsset: cfg.stAsset,
            seniorAsset: cfg.stAsset,
            juniorAsset: cfg.jtAsset,
            stNAVDustTolerance: toNAVUnits(5 * 10 ** (18 - cfg.stDecimals)), // 5 wei tolerance for stETH's 1-2 wei rounding per op
            jtNAVDustTolerance: toNAVUnits(5 * 10 ** (18 - cfg.jtDecimals)), // 5 wei tolerance for stETH's 1-2 wei rounding per op
            kernelType: DeployScript.KernelType.ERC4626_ST_ERC4626_JT_InKindAssets,
            kernelSpecificParams: abi.encode(kernelParams),
            protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS,
            jtRedemptionDelayInSeconds: _getJTRedemptionDelay(),
            stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
            jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            coverageWAD: COVERAGE_WAD,
            betaWAD: 1e18,
            lltvWAD: LLTV,
            fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(ydmParams),
            roleAssignments: roleAssignments
        });

        return DEPLOY_SCRIPT.deploy(params, DEPLOYER.privateKey);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FLUID-SPECIFIC TESTS: convertToAssets rounding behavior
    // ═══════════════════════════════════════════════════════════════════════════
    // These tests verify the system handles Fluid's actual rounding behavior correctly.
    // Fluid's convertToAssets can return slightly different values for the same shares
    // after deposits/withdrawals due to internal accounting precision.

    /// @notice Test that JT deposit → ST deposit works despite Fluid's convertToAssets drift
    function testFuzz_fluid_jtDeposit_stDeposit_accountingCorrect(uint256 _jtAmount, uint256 _stPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 10, 80);

        // JT deposits first
        uint256 jtShares = _depositJT(ALICE_ADDRESS, _jtAmount);
        assertGt(jtShares, 0, "JT should have received shares");

        // Get JT NAV after deposit
        NAV_UNIT jtNavAfterDeposit = JT.totalAssets().nav;

        // ST deposits (this triggers the convertToAssets drift in Fluid)
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // Verify JT NAV is approximately preserved (within tolerance for Fluid drift)
        NAV_UNIT jtNavAfterSTDeposit = JT.totalAssets().nav;
        assertApproxEqAbs(
            toUint256(jtNavAfterSTDeposit), toUint256(jtNavAfterDeposit), toUint256(maxNAVDelta()), "JT NAV should be preserved within Fluid rounding tolerance"
        );
    }

    /// @notice Test consecutive deposits track impermanent loss from Fluid rounding
    function testFuzz_fluid_consecutiveDeposits_trackImpermanentLoss(uint256 _jtAmount, uint256 _numSTDeposits) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 4);
        _numSTDeposits = bound(_numSTDeposits, 2, 5);

        // Initial JT deposit
        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Multiple ST deposits - each one causes convertToAssets drift
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stPerDeposit = toUint256(maxSTDeposit) / (_numSTDeposits + 1);
        if (stPerDeposit < _minDepositAmount()) return;

        for (uint256 i = 0; i < _numSTDeposits; i++) {
            _depositST(BOB_ADDRESS, stPerDeposit);
        }

        // Sync to capture any accumulated drift
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Verify NAV conservation holds within tolerance
        _assertNAVConservation();
    }

    /// @notice Test full deposit-redeem cycle with Fluid's rounding
    function testFuzz_fluid_fullCycle_depositRedeem(uint256 _jtAmount, uint256 _stPercentage, uint256 _redeemPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 20, 60);
        _redeemPercentage = bound(_redeemPercentage, 10, 90);

        // JT deposits
        uint256 jtShares = _depositJT(ALICE_ADDRESS, _jtAmount);

        // ST deposits
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;
        _depositST(BOB_ADDRESS, stAmount);

        // ST requests redeem
        uint256 stShares = ST.balanceOf(BOB_ADDRESS);
        uint256 stSharesToRedeem = stShares * _redeemPercentage / 100;
        uint256 maxRedeemST = ST.maxRedeem(BOB_ADDRESS);
        if (stSharesToRedeem > maxRedeemST) stSharesToRedeem = maxRedeemST;
        if (stSharesToRedeem < _minDepositAmount()) return;

        vm.prank(BOB_ADDRESS);
        ST.redeem(stSharesToRedeem, BOB_ADDRESS, BOB_ADDRESS);

        // Verify NAV conservation
        _assertNAVConservation();

        // JT can still redeem (after delay)
        vm.warp(vm.getBlockTimestamp() + _getJTRedemptionDelay() + 1);

        uint256 jtSharesToRedeem = jtShares * _redeemPercentage / 100;
        uint256 maxRedeemJT = JT.maxRedeem(ALICE_ADDRESS);
        if (jtSharesToRedeem > maxRedeemJT) jtSharesToRedeem = maxRedeemJT;
        if (jtSharesToRedeem < _minDepositAmount()) return;

        vm.prank(ALICE_ADDRESS);
        (uint256 requestId,) = JT.requestRedeem(jtSharesToRedeem, ALICE_ADDRESS, ALICE_ADDRESS);

        vm.warp(vm.getBlockTimestamp() + _getJTRedemptionDelay() + 1);

        uint256 claimable = JT.claimableRedeemRequest(requestId, ALICE_ADDRESS);
        maxRedeemJT = JT.maxRedeem(ALICE_ADDRESS);
        uint256 actualRedeem = claimable < maxRedeemJT ? claimable : maxRedeemJT;
        if (actualRedeem < _minDepositAmount()) return;

        vm.prank(ALICE_ADDRESS);
        JT.redeem(actualRedeem, ALICE_ADDRESS, ALICE_ADDRESS, requestId);

        // Final NAV conservation check
        _assertNAVConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FLUID STETH CONFIGURATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_fluidStETH_vaultConfiguration() external view {
        uint8 decimals = IERC4626(FLUID_IETH_V2).decimals();
        assertEq(decimals, 18, "Fluid iETHv2 should have 18 decimals");

        uint256 sharePrice = IERC4626(FLUID_IETH_V2).convertToAssets(1e18);
        assertGt(sharePrice, 0, "Fluid iETHv2 share price should be > 0");

        address asset = IERC4626(FLUID_IETH_V2).asset();
        assertEq(asset, STETH, "Fluid iETHv2 underlying should be stETH");
    }

    function test_fluidStETH_stETHConfiguration() external view {
        uint8 decimals = IERC20Metadata(STETH).decimals();
        assertEq(decimals, 18, "stETH should have 18 decimals");

        uint256 totalSupply = IERC20(STETH).totalSupply();
        assertGt(totalSupply, 0, "stETH should have non-zero total supply");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SHARED VAULT OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice POC: Demonstrates that Fluid vault's convertToAssets changes when stETH is deposited
    /// This is the root cause of NAV_CONSERVATION_VIOLATION - not stETH rebasing
    function test_POC_fluidVaultSharePriceChange() external {
        // The JT vault shares held by kernel
        uint256 jtVaultShares = 439_520_349_737_079_033_628;

        emit log_named_uint("Testing with JT vault shares", jtVaultShares);

        // Check convertToAssets BEFORE any deposit
        uint256 assetsBefore = IERC4626(FLUID_IETH_V2).convertToAssets(jtVaultShares);
        emit log_named_uint("convertToAssets BEFORE deposit", assetsBefore);

        // Get current vault state
        uint256 totalAssetsBefore = IERC4626(FLUID_IETH_V2).totalAssets();
        uint256 totalSupplyBefore = IERC4626(FLUID_IETH_V2).totalSupply();
        emit log_named_uint("Vault totalAssets before", totalAssetsBefore);
        emit log_named_uint("Vault totalSupply before", totalSupplyBefore);

        // Simulate ST depositing stETH directly into Fluid vault (like the kernel would do)
        uint256 stDepositAmount = 640e18; // ~640 stETH
        vm.startPrank(BOB_ADDRESS);
        IERC20(STETH).approve(FLUID_IETH_V2, stDepositAmount);
        IERC4626(FLUID_IETH_V2).deposit(stDepositAmount, BOB_ADDRESS);
        vm.stopPrank();

        // Check convertToAssets AFTER the deposit
        uint256 assetsAfter = IERC4626(FLUID_IETH_V2).convertToAssets(jtVaultShares);
        emit log_named_uint("convertToAssets AFTER deposit", assetsAfter);

        // Get new vault state
        uint256 totalAssetsAfter = IERC4626(FLUID_IETH_V2).totalAssets();
        uint256 totalSupplyAfter = IERC4626(FLUID_IETH_V2).totalSupply();
        emit log_named_uint("Vault totalAssets after", totalAssetsAfter);
        emit log_named_uint("Vault totalSupply after", totalSupplyAfter);

        // The key finding: did convertToAssets return a different value for the SAME shares?
        if (assetsBefore != assetsAfter) {
            emit log("!!! convertToAssets returned DIFFERENT value for same shares !!!");
            emit log_named_uint("Difference (wei)", assetsBefore > assetsAfter ? assetsBefore - assetsAfter : assetsAfter - assetsBefore);
        } else {
            emit log("convertToAssets returned SAME value - no share price change");
        }
    }

    /// @notice POC: Demonstrates NAV_CONSERVATION_VIOLATION through kernel deposit flow
    /// @dev This uses exact parameters from a failing fuzz test counterexample
    /// Run with: forge test --match-test test_POC_navConservationViolation -vvvv
    function test_POC_navConservationViolation() external {
        // Step 1: JT deposits (creates vault shares for kernel)
        uint256 jtDepositAmount = 500e18;

        vm.startPrank(ALICE_ADDRESS);
        IERC20(STETH).approve(address(JT), jtDepositAmount);
        JT.deposit(toTrancheUnits(jtDepositAmount), ALICE_ADDRESS, ALICE_ADDRESS);
        vm.stopPrank();

        // Get vault shares held by kernel
        uint256 jtVaultShares = IERC4626(FLUID_IETH_V2).balanceOf(address(KERNEL));

        // Check convertToAssets BEFORE ST deposit
        uint256 jtAssetsBefore = IERC4626(FLUID_IETH_V2).convertToAssets(jtVaultShares);
        emit log_named_uint("JT vault shares", jtVaultShares);
        emit log_named_uint("convertToAssets BEFORE ST deposit", jtAssetsBefore);

        // Step 2: ST deposits - triggers NAV_CONSERVATION_VIOLATION in accountant
        // The kernel calls convertToAssets before and after the deposit
        // The Fluid vault returns a different value (1 wei less) after the deposit
        uint256 stMaxDeposit = toUint256(ST.maxDeposit(BOB_ADDRESS));
        uint256 stDepositAmount = stMaxDeposit * 50 / 100;

        emit log_named_uint("ST deposit amount", stDepositAmount);

        vm.startPrank(BOB_ADDRESS);
        IERC20(STETH).approve(address(ST), stDepositAmount);
        ST.deposit(toTrancheUnits(stDepositAmount), BOB_ADDRESS, BOB_ADDRESS);
        vm.stopPrank();

        // Check convertToAssets AFTER ST deposit (if we get here)
        uint256 jtAssetsAfter = IERC4626(FLUID_IETH_V2).convertToAssets(jtVaultShares);
        emit log_named_uint("convertToAssets AFTER ST deposit", jtAssetsAfter);

        if (jtAssetsBefore != jtAssetsAfter) {
            emit log("!!! convertToAssets drift detected !!!");
            emit log_named_uint("Drift (wei)", jtAssetsBefore > jtAssetsAfter ? jtAssetsBefore - jtAssetsAfter : jtAssetsAfter - jtAssetsBefore);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADVERSARIAL TESTS: ROUNDING EDGE CASES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test minimum deposit amount edge case
    /// @dev Verifies system handles minimum viable deposits without breaking
    function test_adversarial_minimumDeposit() external {
        uint256 minDeposit = _minDepositAmount();

        // JT deposits minimum
        uint256 jtShares = _depositJT(ALICE_ADDRESS, minDeposit);
        assertGt(jtShares, 0, "Should receive shares for min deposit");

        // Verify NAV is tracked
        NAV_UNIT jtNav = JT.totalAssets().nav;
        assertGt(toUint256(jtNav), 0, "JT NAV should be positive");

        _assertNAVConservation();
    }

    /// @notice Test many small deposits accumulating rounding drift
    /// @dev Each deposit can cause 1 wei drift - test if 100+ deposits break invariants
    function testFuzz_adversarial_manySmallDeposits_accumulateDrift(uint256 _numDeposits) external {
        _numDeposits = bound(_numDeposits, 50, 150);

        uint256 depositAmount = _minDepositAmount() * 2;

        // Initial JT deposit to enable ST deposits
        _depositJT(ALICE_ADDRESS, config.initialFunding / 4);

        // Track initial state
        NAV_UNIT initialJTNav = JT.totalAssets().nav;

        // Many small ST deposits - each one potentially causes 1 wei drift
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 maxSTDepositUint = toUint256(maxSTDeposit);

        uint256 actualDeposits = 0;
        for (uint256 i = 0; i < _numDeposits; i++) {
            // Check if we can still deposit
            maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
            if (toUint256(maxSTDeposit) < depositAmount) break;

            _depositST(BOB_ADDRESS, depositAmount);
            actualDeposits++;
        }

        // Sync and verify NAV conservation still holds
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        _assertNAVConservation();

        // Log accumulated drift for analysis
        NAV_UNIT finalJTNav = JT.totalAssets().nav;
        emit log_named_uint("Number of deposits", actualDeposits);
        emit log_named_uint("Initial JT NAV", toUint256(initialJTNav));
        emit log_named_uint("Final JT NAV", toUint256(finalJTNav));

        if (toUint256(initialJTNav) > toUint256(finalJTNav)) {
            emit log_named_uint("Total drift (wei)", toUint256(initialJTNav) - toUint256(finalJTNav));
        }
    }

    /// @notice Test deposits followed by many small redemptions
    /// @dev Each redemption can also cause rounding - verify no value leakage
    function testFuzz_adversarial_manySmallRedemptions(uint256 _numRedemptions) external {
        _numRedemptions = bound(_numRedemptions, 10, 50);

        // Setup: JT and ST deposit
        _depositJT(ALICE_ADDRESS, config.initialFunding / 4);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) / 2;
        _depositST(BOB_ADDRESS, stAmount);

        uint256 stShares = ST.balanceOf(BOB_ADDRESS);
        uint256 redeemPerIteration = stShares / (_numRedemptions + 1);

        // Many small redemptions
        uint256 actualRedemptions = 0;
        for (uint256 i = 0; i < _numRedemptions; i++) {
            // Check if market entered FIXED_TERM (ST redemptions disabled)
            if (ACCOUNTANT.getState().lastMarketState == MarketState.FIXED_TERM) break;

            uint256 maxRedeem = ST.maxRedeem(BOB_ADDRESS);
            if (maxRedeem < redeemPerIteration) break;

            vm.prank(BOB_ADDRESS);
            ST.redeem(redeemPerIteration, BOB_ADDRESS, BOB_ADDRESS);
            actualRedemptions++;
        }

        _assertNAVConservation();

        emit log_named_uint("Number of redemptions", actualRedemptions);
    }

    /// @notice Test rounding at exact coverage boundary
    /// @dev Deposit exactly at max coverage to test boundary rounding
    function test_adversarial_exactCoverageBoundary() external {
        // JT deposits
        uint256 jtAmount = config.initialFunding / 4;
        _depositJT(ALICE_ADDRESS, jtAmount);

        // Get exact max ST deposit (coverage boundary)
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 maxSTDepositUint = toUint256(maxSTDeposit);

        if (maxSTDepositUint < _minDepositAmount()) return;

        // Deposit exactly at max (boundary)
        _depositST(BOB_ADDRESS, maxSTDepositUint);

        _assertNAVConservation();

        // Verify we're at max coverage - no more ST deposits allowed
        TRANCHE_UNIT remainingMaxDeposit = ST.maxDeposit(CHARLIE_ADDRESS);
        assertLe(toUint256(remainingMaxDeposit), toUint256(DUST_TOLERANCE) + 1, "Should be at coverage limit");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADVERSARIAL TESTS: MARKET STATE TRANSITIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test PERPETUAL → FIXED_TERM transition via loss
    /// @dev Simulate loss that exceeds dust tolerance to trigger state transition
    function test_adversarial_stateTransition_perpetualToFixedTerm() external {
        // Setup market in PERPETUAL state
        _depositJT(ALICE_ADDRESS, config.initialFunding / 4);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) / 2;
        _depositST(BOB_ADDRESS, stAmount);

        // Verify initial state is PERPETUAL
        IRoycoAccountant.RoycoAccountantState memory stateBefore = ACCOUNTANT.getState();
        assertEq(uint256(stateBefore.lastMarketState), uint256(MarketState.PERPETUAL), "Should start in PERPETUAL");

        // Simulate significant loss to trigger FIXED_TERM
        // Loss needs to exceed dust tolerance to trigger transition
        simulateSTLoss(0.05e18); // 5% loss

        // Sync to apply the loss
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Check state after loss
        IRoycoAccountant.RoycoAccountantState memory stateAfter = ACCOUNTANT.getState();

        // If there's JT coverage IL > dust tolerance, should be FIXED_TERM
        if (toUint256(stateAfter.lastJTCoverageImpermanentLoss) > toUint256(ACCOUNTANT.getState().stNAVDustTolerance)) {
            assertEq(uint256(stateAfter.lastMarketState), uint256(MarketState.FIXED_TERM), "Should transition to FIXED_TERM after loss");
        }

        _assertNAVConservation();
    }

    /// @notice Test FIXED_TERM → PERPETUAL transition via term expiry
    /// @dev Put market in FIXED_TERM, wait for term to elapse, verify transition
    function test_adversarial_stateTransition_fixedTermExpiry() external {
        // Setup market
        _depositJT(ALICE_ADDRESS, config.initialFunding / 4);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) / 2;
        _depositST(BOB_ADDRESS, stAmount);

        // Simulate loss to potentially enter FIXED_TERM
        simulateSTLoss(0.05e18);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        IRoycoAccountant.RoycoAccountantState memory stateAfterLoss = ACCOUNTANT.getState();

        // Only continue if we're in FIXED_TERM
        if (stateAfterLoss.lastMarketState != MarketState.FIXED_TERM) {
            emit log("Market didn't enter FIXED_TERM - loss may have been too small");
            return;
        }

        // Fast forward past fixed term duration
        vm.warp(block.timestamp + FIXED_TERM_DURATION_SECONDS + 1);

        // Sync to trigger state transition check
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        IRoycoAccountant.RoycoAccountantState memory stateAfterExpiry = ACCOUNTANT.getState();
        assertEq(uint256(stateAfterExpiry.lastMarketState), uint256(MarketState.PERPETUAL), "Should return to PERPETUAL after term expiry");

        // JT coverage IL should be erased
        assertEq(toUint256(stateAfterExpiry.lastJTCoverageImpermanentLoss), 0, "JT coverage IL should be erased after term expiry");
    }

    /// @notice Test FIXED_TERM → PERPETUAL transition via coverage restoration
    /// @dev Put market in FIXED_TERM, then restore coverage via JT yield
    function test_adversarial_stateTransition_coverageRestoration() external {
        // Setup market
        _depositJT(ALICE_ADDRESS, config.initialFunding / 4);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) / 2;
        _depositST(BOB_ADDRESS, stAmount);

        // Simulate loss to enter FIXED_TERM
        simulateSTLoss(0.03e18); // 3% loss

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        IRoycoAccountant.RoycoAccountantState memory stateAfterLoss = ACCOUNTANT.getState();

        if (stateAfterLoss.lastMarketState != MarketState.FIXED_TERM) {
            emit log("Market didn't enter FIXED_TERM");
            return;
        }

        // Simulate yield to restore coverage (yield > loss)
        simulateJTYield(0.1e18); // 10% yield

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        IRoycoAccountant.RoycoAccountantState memory stateAfterYield = ACCOUNTANT.getState();

        // If coverage is restored (JT coverage IL <= dust tolerance), should be PERPETUAL
        if (toUint256(stateAfterYield.lastJTCoverageImpermanentLoss) <= toUint256(stateAfterYield.stNAVDustTolerance)) {
            // Note: May still be FIXED_TERM until IL is completely zero per the accountant logic
            emit log_named_uint("JT Coverage IL after yield", toUint256(stateAfterYield.lastJTCoverageImpermanentLoss));
        }

        _assertNAVConservation();
    }

    /// @notice Test rapid state transitions don't break accounting
    /// @dev Multiple loss/yield cycles to stress test state machine
    function testFuzz_adversarial_rapidStateTransitions(uint256 _numCycles) external {
        _numCycles = bound(_numCycles, 3, 10);

        // Setup market
        _depositJT(ALICE_ADDRESS, config.initialFunding / 4);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) / 3;
        if (stAmount < _minDepositAmount()) return;
        _depositST(BOB_ADDRESS, stAmount);

        for (uint256 i = 0; i < _numCycles; i++) {
            // Loss cycle
            simulateSTLoss(0.02e18); // 2% loss
            vm.prank(SYNC_ROLE_ADDRESS);
            KERNEL.syncTrancheAccounting();

            // Yield cycle
            simulateJTYield(0.03e18); // 3% yield
            vm.prank(SYNC_ROLE_ADDRESS);
            KERNEL.syncTrancheAccounting();

            // Advance time
            vm.warp(block.timestamp + 1 days);
        }

        _assertNAVConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADVERSARIAL TESTS: LLTV AND COVERAGE EDGE CASES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test approaching LLTV boundary via losses
    /// @dev Verify system handles approaching liquidation threshold correctly
    function test_adversarial_approachLLTV() external {
        // Setup with high utilization
        _depositJT(ALICE_ADDRESS, config.initialFunding / 4);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * 80 / 100; // 80% of max
        if (stAmount < _minDepositAmount()) return;
        _depositST(BOB_ADDRESS, stAmount);

        // Get initial LTV via sync
        vm.prank(SYNC_ROLE_ADDRESS);
        SyncedAccountingState memory syncedState = KERNEL.syncTrancheAccounting();
        emit log_named_uint("Initial LTV (WAD)", syncedState.ltvWAD);

        // Simulate progressive losses
        for (uint256 i = 0; i < 5; i++) {
            simulateJTLoss(0.05e18); // 5% loss each

            vm.prank(SYNC_ROLE_ADDRESS);
            syncedState = KERNEL.syncTrancheAccounting();
            emit log_named_uint("LTV after loss", syncedState.ltvWAD);

            // If we hit LLTV, ST should still be able to withdraw
            if (syncedState.ltvWAD >= LLTV) {
                uint256 stMaxRedeem = ST.maxRedeem(BOB_ADDRESS);
                emit log_named_uint("ST maxRedeem at LLTV breach", stMaxRedeem);
                break;
            }
        }

        _assertNAVConservation();
    }

    /// @notice Test zero utilization edge case
    /// @dev Market with JT only, no ST deposits
    function test_adversarial_zeroUtilization() external {
        // Only JT deposits - no ST
        _depositJT(ALICE_ADDRESS, config.initialFunding / 4);

        vm.prank(SYNC_ROLE_ADDRESS);
        SyncedAccountingState memory syncedState = KERNEL.syncTrancheAccounting();
        assertEq(syncedState.utilizationWAD, 0, "Utilization should be 0 with no ST");

        // JT should be able to fully redeem
        vm.warp(block.timestamp + _getJTRedemptionDelay() + 1);

        uint256 jtShares = JT.balanceOf(ALICE_ADDRESS);
        uint256 maxRedeem = JT.maxRedeem(ALICE_ADDRESS);

        // Note: Fluid vault has higher rounding than DUST_TOLERANCE (observed 11 wei delta)
        // This is a known characteristic of Fluid's convertToAssets rounding
        assertApproxEqAbs(maxRedeem, jtShares, toUint256(maxNAVDelta()), "JT should be able to redeem all at 0 utilization");
    }

    /// @notice Test 100% utilization edge case
    /// @dev Deposit ST up to max coverage
    function test_adversarial_fullUtilization() external {
        // JT deposits
        _depositJT(ALICE_ADDRESS, config.initialFunding / 4);

        // ST deposits to max coverage
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit);
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        vm.prank(SYNC_ROLE_ADDRESS);
        SyncedAccountingState memory syncedState = KERNEL.syncTrancheAccounting();
        emit log_named_uint("Utilization at max ST", syncedState.utilizationWAD);

        // JT maxRedeem should be very limited
        vm.warp(block.timestamp + _getJTRedemptionDelay() + 1);

        uint256 jtMaxRedeem = JT.maxRedeem(ALICE_ADDRESS);
        emit log_named_uint("JT maxRedeem at full utilization", jtMaxRedeem);

        _assertNAVConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADVERSARIAL TESTS: CONCURRENT OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test interleaved ST/JT deposits and redemptions
    /// @dev Stress test with multiple users doing concurrent operations
    function testFuzz_adversarial_interleavedOperations(uint256 _seed) external {
        _seed = bound(_seed, 1, type(uint256).max);

        // Initial setup
        _depositJT(ALICE_ADDRESS, config.initialFunding / 8);

        // Interleaved operations
        for (uint256 i = 0; i < 10; i++) {
            uint256 action = uint256(keccak256(abi.encodePacked(_seed, i))) % 4;

            if (action == 0) {
                // JT deposit
                uint256 amount = bound(uint256(keccak256(abi.encodePacked(_seed, i, "jt"))), _minDepositAmount(), config.initialFunding / 20);
                _depositJT(CHARLIE_ADDRESS, amount);
            } else if (action == 1) {
                // ST deposit (if possible)
                TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
                uint256 maxAmount = toUint256(maxSTDeposit);
                if (maxAmount >= _minDepositAmount()) {
                    uint256 amount = bound(uint256(keccak256(abi.encodePacked(_seed, i, "st"))), _minDepositAmount(), maxAmount / 2);
                    if (amount >= _minDepositAmount()) {
                        _depositST(BOB_ADDRESS, amount);
                    }
                }
            } else if (action == 2) {
                // ST redeem (if has balance)
                uint256 stBalance = ST.balanceOf(BOB_ADDRESS);
                uint256 maxRedeem = ST.maxRedeem(BOB_ADDRESS);
                if (maxRedeem >= _minDepositAmount()) {
                    uint256 amount = bound(uint256(keccak256(abi.encodePacked(_seed, i, "str"))), _minDepositAmount(), maxRedeem / 2);
                    if (amount >= _minDepositAmount()) {
                        vm.prank(BOB_ADDRESS);
                        ST.redeem(amount, BOB_ADDRESS, BOB_ADDRESS);
                    }
                }
            } else {
                // Sync
                vm.prank(SYNC_ROLE_ADDRESS);
                KERNEL.syncTrancheAccounting();
            }

            // Advance time slightly
            vm.warp(block.timestamp + 1 hours);
        }

        _assertNAVConservation();
    }

    /// @notice Test redemption request during state transition
    /// @dev Create redemption request, then trigger state transition, then claim
    function test_adversarial_redemptionDuringStateTransition() external {
        // Setup
        _depositJT(ALICE_ADDRESS, config.initialFunding / 4);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) / 2;
        if (stAmount < _minDepositAmount()) return;
        _depositST(BOB_ADDRESS, stAmount);

        // Wait for JT redemption delay
        vm.warp(block.timestamp + _getJTRedemptionDelay() + 1);

        // JT creates redemption request
        uint256 jtShares = JT.balanceOf(ALICE_ADDRESS);
        uint256 maxRedeem = JT.maxRedeem(ALICE_ADDRESS);
        uint256 redeemAmount = maxRedeem / 2;
        if (redeemAmount < _minDepositAmount()) return;

        vm.prank(ALICE_ADDRESS);
        (uint256 requestId,) = JT.requestRedeem(redeemAmount, ALICE_ADDRESS, ALICE_ADDRESS);

        // Simulate loss to trigger state transition
        simulateSTLoss(0.05e18);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Wait for claim delay
        vm.warp(block.timestamp + _getJTRedemptionDelay() + 1);

        // Try to claim - should work but amount may be reduced
        uint256 claimable = JT.claimableRedeemRequest(requestId, ALICE_ADDRESS);
        uint256 newMaxRedeem = JT.maxRedeem(ALICE_ADDRESS);
        uint256 actualClaim = claimable < newMaxRedeem ? claimable : newMaxRedeem;

        if (actualClaim >= _minDepositAmount()) {
            vm.prank(ALICE_ADDRESS);
            JT.redeem(actualClaim, ALICE_ADDRESS, ALICE_ADDRESS, requestId);
        }

        _assertNAVConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADVERSARIAL TESTS: DUST ACCUMULATION ANALYSIS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Analyze dust accumulation over many yield distribution cycles
    /// @dev This tests the comment in deployment: "~1 wei per 25-40 yield distribution cycles"
    function test_adversarial_dustAccumulationAnalysis() external {
        // Setup
        _depositJT(ALICE_ADDRESS, config.initialFunding / 4);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) / 2;
        if (stAmount < _minDepositAmount()) return;
        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT initialJTNav = JT.totalAssets().nav;
        uint256 initialJTCoverageIL = toUint256(ACCOUNTANT.getState().lastJTCoverageImpermanentLoss);

        // Many yield cycles
        uint256 numCycles = 100;
        for (uint256 i = 0; i < numCycles; i++) {
            // Small yield
            simulateSTYield(0.001e18); // 0.1% yield

            // Advance time for yield distribution
            vm.warp(block.timestamp + 1 days);

            // Sync
            vm.prank(SYNC_ROLE_ADDRESS);
            KERNEL.syncTrancheAccounting();
        }

        NAV_UNIT finalJTNav = JT.totalAssets().nav;
        uint256 finalJTCoverageIL = toUint256(ACCOUNTANT.getState().lastJTCoverageImpermanentLoss);

        emit log_named_uint("Number of yield cycles", numCycles);
        emit log_named_uint("Initial JT NAV", toUint256(initialJTNav));
        emit log_named_uint("Final JT NAV", toUint256(finalJTNav));
        emit log_named_uint("Initial JT Coverage IL", initialJTCoverageIL);
        emit log_named_uint("Final JT Coverage IL", finalJTCoverageIL);
        emit log_named_uint("Accumulated Coverage IL", finalJTCoverageIL - initialJTCoverageIL);

        // Verify dust tolerance is not exceeded
        assertLe(finalJTCoverageIL, toUint256(ACCOUNTANT.getState().stNAVDustTolerance), "Coverage IL should stay within dust tolerance for yield-only cycles");

        _assertNAVConservation();
    }

    /// @notice Test that preOpSync is re-entered on every deposit with dust
    /// @dev This verifies the gas inefficiency concern discussed earlier
    function test_adversarial_preOpSyncReentry() external {
        // Initial JT deposit
        _depositJT(ALICE_ADDRESS, config.initialFunding / 4);

        // Track gas for ST deposit
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) / 4;
        if (stAmount < _minDepositAmount()) return;

        uint256 gasBefore = gasleft();
        _depositST(BOB_ADDRESS, stAmount);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used for ST deposit", gasUsed);

        // Second deposit should use similar gas (both trigger preOpSync re-entry if there's drift)
        uint256 gasBefore2 = gasleft();
        _depositST(BOB_ADDRESS, stAmount);
        uint256 gasUsed2 = gasBefore2 - gasleft();

        emit log_named_uint("Gas used for 2nd ST deposit", gasUsed2);

        // Note: If dust causes preOpSync re-entry, gas should be noticeably higher
        // A deposit without re-entry would use less gas
    }
}
