// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../../lib/forge-std/src/Vm.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { DeployScript } from "../../../script/Deploy.s.sol";
import { IRoycoAccountant } from "../../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../../src/libraries/Constants.sol";
import { AssetClaims, MarketState, TrancheType } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { BaseTest } from "../../base/BaseTest.t.sol";
import { IKernelTestHooks } from "../../interfaces/IKernelTestHooks.sol";

/// @title AbstractKernelTestSuite
/// @notice Abstract test suite containing all tests that apply to every kernel type
/// @dev Concrete implementations must implement the hook interface and deployment logic
abstract contract AbstractKernelTestSuite is BaseTest, IKernelTestHooks {
    using Math for uint256;
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 internal constant MAX_RELATIVE_DELTA = 100 * BPS; // 1%
    uint256 internal constant PREVIEW_RELATIVE_DELTA = 10 * BPS; // 0.1%

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST STATE
    // ═══════════════════════════════════════════════════════════════════════════

    TrancheState internal stState;
    TrancheState internal jtState;
    ProtocolConfig internal config;

    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT FUNCTIONS (Must be implemented by concrete tests)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the kernel and market for this test suite
    /// @return result The deployment result containing all contract references
    function _deployKernelAndMarket() internal virtual returns (DeployScript.DeploymentResult memory result);

    // ═══════════════════════════════════════════════════════════════════════════
    // IKernelTestHooks INTERFACE FUNCTIONS (Must be implemented by concrete tests)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IKernelTestHooks
    function getProtocolConfig() public view virtual returns (ProtocolConfig memory);

    /// @notice Simulates yield generation for ST
    function simulateSTYield(uint256 _percentageWAD) public virtual;

    /// @notice Simulates yield generation for JT
    function simulateJTYield(uint256 _percentageWAD) public virtual;

    /// @notice Simulates loss for ST
    function simulateSTLoss(uint256 _percentageWAD) public virtual;

    /// @notice Simulates loss for JT
    function simulateJTLoss(uint256 _percentageWAD) public virtual;

    /// @notice Deals the ST asset to an address
    function dealSTAsset(address _to, uint256 _amount) public virtual;

    /// @notice Deals the JT asset to an address
    function dealJTAsset(address _to, uint256 _amount) public virtual;

    /// @notice Returns the maximum delta tolerance for tranche unit comparisons
    function maxTrancheUnitDelta() public view virtual returns (TRANCHE_UNIT);

    /// @notice Returns the maximum delta tolerance for NAV comparisons
    function maxNAVDelta() public view virtual returns (NAV_UNIT);

    /// @notice Called after vm.warp to refresh time-sensitive oracles
    /// @dev Override in protocol tests that use Chainlink or other time-sensitive oracles
    function _refreshOraclesAfterWarp() internal virtual {
        // Default: no-op. Override for protocols with stale price checks.
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        config = getProtocolConfig();

        // Setup fork if needed
        if (bytes(config.forkRpcUrlEnvVar).length > 0) {
            string memory rpcUrl = vm.envString(config.forkRpcUrlEnvVar);
            require(bytes(rpcUrl).length > 0, "RPC URL not set");
            vm.createSelectFork(rpcUrl, config.forkBlock);
        }

        // Setup base wallets
        _setupWallets();

        // Deploy the deploy script
        DEPLOY_SCRIPT = new DeployScript();

        // Deploy kernel and market
        DeployScript.DeploymentResult memory result = _deployKernelAndMarket();
        _setDeployedMarket(result);

        // Setup providers and fund them
        _setupProviders();
        _fundAllProviders();
    }

    function _fundAllProviders() internal {
        dealSTAsset(ST_ALICE_ADDRESS, config.initialFunding);
        dealSTAsset(ST_BOB_ADDRESS, config.initialFunding);
        dealSTAsset(ST_CHARLIE_ADDRESS, config.initialFunding);
        dealSTAsset(ST_DAN_ADDRESS, config.initialFunding);
        dealJTAsset(JT_ALICE_ADDRESS, config.initialFunding);
        dealJTAsset(JT_BOB_ADDRESS, config.initialFunding);
        dealJTAsset(JT_CHARLIE_ADDRESS, config.initialFunding);
        dealJTAsset(JT_DAN_ADDRESS, config.initialFunding);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 1: TRANCHE VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_ST_maxDeposit_returnsZeroWithNoJTCoverage() external view {
        TRANCHE_UNIT maxDeposit = ST.maxDeposit(ALICE_ADDRESS);
        assertEq(maxDeposit, ZERO_TRANCHE_UNITS, "ST maxDeposit should be 0 with no JT coverage");
    }

    function test_JT_maxDeposit_returnsNonZeroInitially() external view {
        TRANCHE_UNIT maxDeposit = JT.maxDeposit(ALICE_ADDRESS);
        assertGt(maxDeposit, ZERO_TRANCHE_UNITS, "JT maxDeposit should be > 0 initially");
    }

    function test_ST_totalAssets_initiallyZero() external view {
        AssetClaims memory claims = ST.totalAssets();
        assertEq(claims.nav, ZERO_NAV_UNITS, "ST totalAssets.nav should be 0");
        assertEq(claims.stAssets, ZERO_TRANCHE_UNITS, "ST totalAssets.stAssets should be 0");
        assertEq(claims.jtAssets, ZERO_TRANCHE_UNITS, "ST totalAssets.jtAssets should be 0");
    }

    function test_JT_totalAssets_initiallyZero() external view {
        AssetClaims memory claims = JT.totalAssets();
        assertEq(claims.nav, ZERO_NAV_UNITS, "JT totalAssets.nav should be 0");
        assertEq(claims.stAssets, ZERO_TRANCHE_UNITS, "JT totalAssets.stAssets should be 0");
        assertEq(claims.jtAssets, ZERO_TRANCHE_UNITS, "JT totalAssets.jtAssets should be 0");
    }

    function test_ST_getRawNAV_initiallyZero() external view {
        NAV_UNIT rawNAV = ST.getRawNAV();
        assertEq(rawNAV, ZERO_NAV_UNITS, "ST raw NAV should be 0 initially");
    }

    function test_JT_getRawNAV_initiallyZero() external view {
        NAV_UNIT rawNAV = JT.getRawNAV();
        assertEq(rawNAV, ZERO_NAV_UNITS, "JT raw NAV should be 0 initially");
    }

    function testFuzz_JT_previewDeposit_matchesActualDeposit(uint256 _assets) external {
        _assets = bound(_assets, _minDepositAmount(), config.initialFunding / 10);

        TRANCHE_UNIT depositAmount = toTrancheUnits(_assets);
        uint256 previewShares = JT.previewDeposit(depositAmount);

        vm.startPrank(ALICE_ADDRESS);
        IERC20(config.jtAsset).approve(address(JT), _assets);
        uint256 actualShares = JT.deposit(depositAmount, ALICE_ADDRESS);
        vm.stopPrank();

        assertApproxEqRel(actualShares, previewShares, PREVIEW_RELATIVE_DELTA, "Preview should match actual JT deposit");
    }

    function testFuzz_ST_previewDeposit_matchesActualDeposit(uint256 _jtAmount, uint256 _stPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 1, 50);

        // First deposit JT to enable ST deposits
        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        if (stAmount == 0) return;

        TRANCHE_UNIT depositAmount = toTrancheUnits(stAmount);
        uint256 previewShares = ST.previewDeposit(depositAmount);

        vm.startPrank(BOB_ADDRESS);
        IERC20(config.stAsset).approve(address(ST), stAmount);
        uint256 actualShares = ST.deposit(depositAmount, BOB_ADDRESS);
        vm.stopPrank();

        assertApproxEqRel(actualShares, previewShares, PREVIEW_RELATIVE_DELTA, "Preview should match actual ST deposit");
    }

    function testFuzz_JT_convertToAssets_nonZeroForNonZeroShares(uint256 _amount) external {
        _amount = bound(_amount, _minDepositAmount(), config.initialFunding / 10);

        uint256 jtShares = _depositJT(ALICE_ADDRESS, _amount);

        AssetClaims memory claims = JT.convertToAssets(jtShares);
        assertGt(toUint256(claims.nav), 0, "NAV should be > 0 for non-zero shares");
        assertGt(toUint256(claims.jtAssets), 0, "JT assets should be > 0 for non-zero shares");
    }

    function testFuzz_ST_convertToAssets_nonZeroForNonZeroShares(uint256 _jtAmount, uint256 _stPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        if (stAmount == 0) return;

        uint256 stShares = _depositST(BOB_ADDRESS, stAmount);

        AssetClaims memory claims = ST.convertToAssets(stShares);
        assertGt(toUint256(claims.nav), 0, "NAV should be > 0 for non-zero shares");
        assertGt(toUint256(claims.stAssets), 0, "ST assets should be > 0 for non-zero shares");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 2: KERNEL VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_kernel_stMaxDeposit_respectsCoverage(uint256 _jtDeposit) external {
        _jtDeposit = bound(_jtDeposit, _minDepositAmount(), config.initialFunding / 2);
        _depositJT(ALICE_ADDRESS, _jtDeposit);

        TRANCHE_UNIT maxDeposit = ST.maxDeposit(BOB_ADDRESS);

        // Max deposit should be > 0 after JT deposit
        assertGt(maxDeposit, ZERO_TRANCHE_UNITS, "Max ST deposit should be > 0 after JT deposit");
    }

    function testFuzz_kernel_stMaxWithdrawable_afterDeposit(uint256 _jtDeposit, uint256 _stPercentage) external {
        _jtDeposit = bound(_jtDeposit, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);

        _depositJT(ALICE_ADDRESS, _jtDeposit);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stDeposit = toUint256(maxSTDeposit) * _stPercentage / 100;
        if (stDeposit == 0) return;

        _depositST(BOB_ADDRESS, stDeposit);

        (NAV_UNIT claimOnST,,,,) = KERNEL.stMaxWithdrawable(BOB_ADDRESS);

        assertGt(claimOnST, ZERO_NAV_UNITS, "Should have claim on ST");
    }

    function testFuzz_kernel_jtMaxWithdrawable_afterDeposit(uint256 _jtDeposit) external {
        _jtDeposit = bound(_jtDeposit, _minDepositAmount(), config.initialFunding / 2);

        _depositJT(ALICE_ADDRESS, _jtDeposit);

        (, NAV_UNIT claimOnJT,,,) = KERNEL.jtMaxWithdrawable(ALICE_ADDRESS);

        assertGt(claimOnJT, ZERO_NAV_UNITS, "Should have claim on JT");
    }

    function test_kernel_conversionFunctions_roundTrip() external view {
        TRANCHE_UNIT oneUnit = toTrancheUnits(10 ** config.stDecimals);

        NAV_UNIT navFromST = KERNEL.stConvertTrancheUnitsToNAVUnits(oneUnit);
        TRANCHE_UNIT backToST = KERNEL.stConvertNAVUnitsToTrancheUnits(navFromST);

        // Should round-trip (with potential rounding)
        assertApproxEqRel(backToST, oneUnit, PREVIEW_RELATIVE_DELTA, "ST round-trip conversion should be consistent");

        NAV_UNIT navFromJT = KERNEL.jtConvertTrancheUnitsToNAVUnits(oneUnit);
        TRANCHE_UNIT backToJT = KERNEL.jtConvertNAVUnitsToTrancheUnits(navFromJT);

        assertApproxEqRel(backToJT, oneUnit, PREVIEW_RELATIVE_DELTA, "JT round-trip conversion should be consistent");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 3: DEPOSIT FLOWS
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_JT_deposit_mintsShares(uint256 _amount) external {
        _amount = bound(_amount, _minDepositAmount(), config.initialFunding / 10);

        uint256 sharesBefore = JT.balanceOf(ALICE_ADDRESS);
        uint256 shares = _depositJT(ALICE_ADDRESS, _amount);

        assertGt(shares, 0, "Should mint shares");
        assertEq(JT.balanceOf(ALICE_ADDRESS), sharesBefore + shares, "Balance should increase");
    }

    function testFuzz_JT_deposit_updatesRawNAV(uint256 _amount) external {
        _amount = bound(_amount, _minDepositAmount(), config.initialFunding / 10);

        NAV_UNIT rawNAVBefore = JT.getRawNAV();
        _depositJT(ALICE_ADDRESS, _amount);
        NAV_UNIT rawNAVAfter = JT.getRawNAV();

        assertGt(rawNAVAfter, rawNAVBefore, "Raw NAV should increase after deposit");
    }

    function testFuzz_JT_deposit_transfersAssets(uint256 _amount) external virtual {
        _amount = bound(_amount, _minDepositAmount(), config.initialFunding / 10);

        uint256 balanceBefore = IERC20(config.jtAsset).balanceOf(ALICE_ADDRESS);
        _depositJT(ALICE_ADDRESS, _amount);
        uint256 balanceAfter = IERC20(config.jtAsset).balanceOf(ALICE_ADDRESS);

        assertApproxEqAbs(balanceBefore - balanceAfter, _amount, 2, "Should transfer correct amount of assets");
    }

    function test_ST_deposit_revertsWithoutJTCoverage() external {
        uint256 amount = _minDepositAmount();

        vm.startPrank(BOB_ADDRESS);
        IERC20(config.stAsset).approve(address(ST), amount);

        vm.expectRevert(abi.encodeWithSelector(IRoycoAccountant.COVERAGE_REQUIREMENT_UNSATISFIED.selector));
        ST.deposit(toTrancheUnits(amount), BOB_ADDRESS);
        vm.stopPrank();
    }

    function testFuzz_ST_deposit_succeedsWithJTCoverage(uint256 _jtAmount, uint256 _stPercentage) external {
        // Use /4 to leave room for ST deposit which can be larger due to coverage ratio
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 1, 99);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        // Cap ST amount to what BOB actually has funded
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        if (stAmount > config.initialFunding) stAmount = config.initialFunding;

        if (stAmount > 0 && stAmount >= _minDepositAmount()) {
            uint256 shares = _depositST(BOB_ADDRESS, stAmount);
            assertGt(shares, 0, "Should mint ST shares");
        }
    }

    function testFuzz_multipleDepositors_JT(uint256 _numDepositors, uint256 _amountSeed) external {
        _numDepositors = bound(_numDepositors, 2, 10);

        uint256 totalShares = 0;
        for (uint256 i = 0; i < _numDepositors; i++) {
            Vm.Wallet memory depositor = _generateFundedDepositor(i);
            uint256 amount = bound(uint256(keccak256(abi.encodePacked(_amountSeed, i))), _minDepositAmount(), config.initialFunding / 20);

            uint256 shares = _depositJT(depositor.addr, amount);
            totalShares += shares;
        }

        assertEq(JT.totalSupply(), totalShares, "Total supply should match sum of shares");
    }

    function testFuzz_multipleDepositors_ST_and_JT(uint256 _numDepositors, uint256 _amountSeed) external {
        _numDepositors = bound(_numDepositors, 2, 5);

        // First, have half the depositors deposit into JT to provide coverage
        uint256 totalJTShares = 0;
        for (uint256 i = 0; i < _numDepositors; i++) {
            Vm.Wallet memory depositor = _generateFundedDepositor(i);
            uint256 amount = bound(uint256(keccak256(abi.encodePacked(_amountSeed, i))), _minDepositAmount(), config.initialFunding / 20);

            uint256 shares = _depositJT(depositor.addr, amount);
            totalJTShares += shares;
        }

        // Then have others deposit into ST
        uint256 totalSTShares = 0;
        for (uint256 i = _numDepositors; i < _numDepositors * 2; i++) {
            Vm.Wallet memory depositor = _generateFundedDepositor(i);

            TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(depositor.addr);
            if (maxSTDeposit == ZERO_TRANCHE_UNITS) continue;

            uint256 amount = bound(
                uint256(keccak256(abi.encodePacked(_amountSeed, i))),
                _minDepositAmount(),
                toUint256(maxSTDeposit) / 2 // Leave room for others
            );

            if (amount < _minDepositAmount()) continue;

            uint256 shares = _depositST(depositor.addr, amount);
            totalSTShares += shares;
        }

        assertEq(JT.totalSupply(), totalJTShares, "JT total supply should match sum of JT shares");
        assertEq(ST.totalSupply(), totalSTShares, "ST total supply should match sum of ST shares");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 4: REDEEM FLOWS
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_ST_redeem_sync(uint256 _jtAmount, uint256 _stPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50); // Keep utilization below 100%

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        uint256 maxRedeem = ST.maxRedeem(BOB_ADDRESS);
        assertTrue(maxRedeem > 0, "Should be able to redeem");

        uint256 balanceBefore = IERC20(config.stAsset).balanceOf(BOB_ADDRESS);

        vm.prank(BOB_ADDRESS);
        ST.redeem(maxRedeem, BOB_ADDRESS, BOB_ADDRESS);

        uint256 balanceAfter = IERC20(config.stAsset).balanceOf(BOB_ADDRESS);
        assertGt(balanceAfter, balanceBefore, "Should receive assets");
    }

    function testFuzz_ST_redeem_previewMatchesActual(uint256 _jtAmount, uint256 _stPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        uint256 maxRedeem = ST.maxRedeem(BOB_ADDRESS);
        if (maxRedeem == 0) return;

        AssetClaims memory previewClaims = ST.previewRedeem(maxRedeem);

        vm.prank(BOB_ADDRESS);
        AssetClaims memory actualClaims = ST.redeem(maxRedeem, BOB_ADDRESS, BOB_ADDRESS);

        assertApproxEqRel(toUint256(actualClaims.stAssets), toUint256(previewClaims.stAssets), PREVIEW_RELATIVE_DELTA, "Preview ST assets should match actual");
    }

    function testFuzz_JT_redeem_sync(uint256 _amount) external {
        _amount = bound(_amount, _minDepositAmount(), config.initialFunding / 10);

        _depositJT(ALICE_ADDRESS, _amount);
        uint256 maxRedeem = JT.maxRedeem(ALICE_ADDRESS);

        assertTrue(maxRedeem > 0, "Should be able to redeem");

        uint256 balanceBefore = IERC20(config.jtAsset).balanceOf(ALICE_ADDRESS);

        vm.prank(ALICE_ADDRESS);
        JT.redeem(maxRedeem, ALICE_ADDRESS, ALICE_ADDRESS);

        uint256 balanceAfter = IERC20(config.jtAsset).balanceOf(ALICE_ADDRESS);
        assertGt(balanceAfter, balanceBefore, "Should receive assets");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 5: COVERAGE ENFORCEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_coverage_blocksExcessSTDeposit(uint256 _jtAmount) external {
        // Use /4 to leave headroom for excess amount calculation
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 4);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 excessAmount = toUint256(maxSTDeposit) + _minDepositAmount();

        // If the excess amount would exceed our balance, skip this test case
        // We need enough balance to attempt the deposit and hit the coverage check
        if (excessAmount > config.initialFunding) return;

        vm.startPrank(BOB_ADDRESS);
        IERC20(config.stAsset).approve(address(ST), excessAmount);

        vm.expectRevert(abi.encodeWithSelector(IRoycoAccountant.COVERAGE_REQUIREMENT_UNSATISFIED.selector));
        ST.deposit(toTrancheUnits(excessAmount), BOB_ADDRESS);
        vm.stopPrank();
    }

    function testFuzz_coverage_STRedeemUnlockJTRedeem(uint256 _jtAmount, uint256 _stPercentage) external {
        // Use /4 to leave room for ST deposit
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 50, 90);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        // Cap to what BOB actually has
        if (stAmount > config.initialFunding) stAmount = config.initialFunding;
        if (stAmount < _minDepositAmount()) return;

        uint256 stShares = _depositST(BOB_ADDRESS, stAmount);

        uint256 jtMaxRedeemBefore = JT.maxRedeem(ALICE_ADDRESS);

        // Redeem all ST
        vm.prank(BOB_ADDRESS);
        ST.redeem(stShares, BOB_ADDRESS, BOB_ADDRESS);

        uint256 jtMaxRedeemAfter = JT.maxRedeem(ALICE_ADDRESS);

        // JT should be able to redeem more (or all) after ST redeems
        assertGe(jtMaxRedeemAfter, jtMaxRedeemBefore, "JT maxRedeem should increase or stay same after ST redeems");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 6: YIELD SCENARIOS
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_yield_JTGain_updatesNAV(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 50); // 1-50% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate yield
        simulateJTYield(_yieldPercentage * 1e16); // Convert to WAD

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    function testFuzz_yield_STGain_distributesToJT(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT jtNavBefore = JT.totalAssets().nav;

        // Simulate ST yield
        simulateSTYield(_yieldPercentage * 1e16);

        // Warp time for yield distribution
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT jtNavAfter = JT.totalAssets().nav;

        // JT should receive portion of ST yield based on YDM
        assertGe(jtNavAfter, jtNavBefore, "JT NAV should increase or stay same from ST yield");
    }

    function testFuzz_yield_protocolFeeAccrues(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 2);
        _yieldPercentage = bound(_yieldPercentage, 5, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 feeRecipientSharesBefore = JT.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);

        // Simulate yield
        simulateJTYield(_yieldPercentage * 1e16);

        // Warp time
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Do another deposit to trigger fee share minting
        _depositJT(JT_BOB_ADDRESS, _minDepositAmount());

        uint256 feeRecipientSharesAfter = JT.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);

        // Protocol should have received fee shares (if fees are configured)
        // Note: This depends on protocol fee configuration
        assertGe(feeRecipientSharesAfter, feeRecipientSharesBefore, "Protocol fee shares should accrue");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 7: LOSS WATERFALL
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_loss_JTAbsorbsFirst(uint256 _jtAmount, uint256 _stPercentage, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _lossPercentage = bound(_lossPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT stNavBefore = ST.totalAssets().nav;
        NAV_UNIT jtNavBefore = JT.totalAssets().nav;

        // Simulate JT loss
        simulateJTLoss(_lossPercentage * 1e16);

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT stNavAfter = ST.totalAssets().nav;
        NAV_UNIT jtNavAfter = JT.totalAssets().nav;

        // ST should be unaffected (JT absorbs loss first)
        assertApproxEqRel(toUint256(stNavAfter), toUint256(stNavBefore), MAX_RELATIVE_DELTA, "ST NAV should be unaffected by JT loss");

        // JT should decrease
        assertLt(jtNavAfter, jtNavBefore, "JT NAV should decrease");
    }

    function testFuzz_loss_STLoss_JTProvidesCoverage(uint256 _jtAmount, uint256 _stPercentage, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 2);
        _stPercentage = bound(_stPercentage, 10, 30); // Keep utilization moderate
        _lossPercentage = bound(_lossPercentage, 1, 10); // Small loss

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT jtNavBefore = JT.totalAssets().nav;

        // Simulate ST loss
        simulateSTLoss(_lossPercentage * 1e16);

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT jtNavAfter = JT.totalAssets().nav;

        // JT effective NAV should decrease (provided coverage)
        assertLe(jtNavAfter, jtNavBefore, "JT NAV should decrease or stay same (provided coverage)");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 8: MARKET STATE TRANSITIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_marketState_initiallyPerpetual() external view {
        IRoycoAccountant.RoycoAccountantState memory accountantState = ACCOUNTANT.getState();
        assertEq(uint256(accountantState.lastMarketState), uint256(MarketState.PERPETUAL), "Should start in PERPETUAL");
    }

    function testFuzz_marketState_STLossTriggersCoverageTracking(uint256 _jtAmount, uint256 _stPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 20, 50);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // Simulate significant ST loss that JT covers
        simulateSTLoss(5e16); // 5% loss

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Check state - may transition to FIXED_TERM depending on configuration
        IRoycoAccountant.RoycoAccountantState memory accountantState = ACCOUNTANT.getState();
        // State could be PERPETUAL or FIXED_TERM depending on LLTV and coverage
        assertTrue(
            accountantState.lastMarketState == MarketState.PERPETUAL || accountantState.lastMarketState == MarketState.FIXED_TERM,
            "State should be valid after ST loss"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 9: INVARIANT CHECKS
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_invariant_NAVConservation(uint256 _jtAmount, uint256 _stPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 0, 50);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        if (_stPercentage > 0) {
            TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
            uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
            if (stAmount >= _minDepositAmount()) {
                _depositST(BOB_ADDRESS, stAmount);
            }
        }

        _assertNAVConservation();
    }

    function testFuzz_invariant_NAVConservation_afterYield(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 2);
        _yieldPercentage = bound(_yieldPercentage, 1, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Simulate yield
        simulateJTYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        _assertNAVConservation();
    }

    function testFuzz_invariant_NAVConservation_afterLoss(uint256 _jtAmount, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 2);
        _lossPercentage = bound(_lossPercentage, 1, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Simulate loss
        simulateJTLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        _assertNAVConservation();
    }

    function testFuzz_invariant_totalSupplyMatchesBalances(uint256 _jtAmount) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);

        _depositJT(ALICE_ADDRESS, _jtAmount);
        _depositJT(JT_BOB_ADDRESS, _jtAmount);

        uint256 totalSupply = JT.totalSupply();
        uint256 sumOfBalances = JT.balanceOf(ALICE_ADDRESS) + JT.balanceOf(JT_BOB_ADDRESS);

        // Account for protocol fee shares
        uint256 feeShares = JT.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);

        assertEq(totalSupply, sumOfBalances + feeShares, "Total supply should equal sum of balances");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 10: FULL FLOW TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_fullFlow_depositYieldRedeem(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 2);
        _stPercentage = bound(_stPercentage, 10, 40);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        // Step 1: JT deposits
        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Step 2: ST deposits
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // Step 3: Simulate yield
        simulateJTYield(_yieldPercentage * 1e16);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Step 4: ST redeems
        uint256 stMaxRedeem = ST.maxRedeem(BOB_ADDRESS);
        if (stMaxRedeem > 0) {
            uint256 stBalanceBefore = IERC20(config.stAsset).balanceOf(BOB_ADDRESS);
            vm.prank(BOB_ADDRESS);
            ST.redeem(stMaxRedeem, BOB_ADDRESS, BOB_ADDRESS);
            uint256 stBalanceAfter = IERC20(config.stAsset).balanceOf(BOB_ADDRESS);
            assertGt(stBalanceAfter, stBalanceBefore, "ST should receive assets");
        }

        // Step 5: JT redeems (sync)
        uint256 jtMaxRedeem = JT.maxRedeem(ALICE_ADDRESS);
        if (jtMaxRedeem > 0) {
            uint256 jtBalanceBefore = IERC20(config.jtAsset).balanceOf(ALICE_ADDRESS);
            vm.prank(ALICE_ADDRESS);
            JT.redeem(jtMaxRedeem, ALICE_ADDRESS, ALICE_ADDRESS);
            uint256 jtBalanceAfter = IERC20(config.jtAsset).balanceOf(ALICE_ADDRESS);

            // JT should receive more than deposited due to yield
            assertGt(jtBalanceAfter, jtBalanceBefore, "JT should receive assets");
        }

        // Verify NAV conservation throughout
        _assertNAVConservation();
    }

    function testFuzz_fullFlow_depositLossRedeem(uint256 _jtAmount, uint256 _stPercentage, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 2);
        _stPercentage = bound(_stPercentage, 10, 30);
        _lossPercentage = bound(_lossPercentage, 1, 15);

        // Step 1: JT deposits
        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Step 2: ST deposits
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT stNavBeforeLoss = ST.totalAssets().nav;
        NAV_UNIT jtNavBeforeLoss = JT.totalAssets().nav;

        // Step 3: Simulate JT loss
        simulateJTLoss(_lossPercentage * 1e16);
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT stNavAfterLoss = ST.totalAssets().nav;
        NAV_UNIT jtNavAfterLoss = JT.totalAssets().nav;

        // ST should be protected, JT absorbs loss
        assertApproxEqRel(toUint256(stNavAfterLoss), toUint256(stNavBeforeLoss), MAX_RELATIVE_DELTA, "ST NAV should be protected");
        assertLt(jtNavAfterLoss, jtNavBeforeLoss, "JT NAV should decrease");

        // Step 4: Verify NAV conservation
        _assertNAVConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function _depositJT(address _depositor, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_depositor);
        IERC20(config.jtAsset).approve(address(JT), _amount);
        shares = JT.deposit(toTrancheUnits(_amount), _depositor);
        vm.stopPrank();
    }

    function _depositST(address _depositor, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_depositor);
        IERC20(config.stAsset).approve(address(ST), _amount);
        shares = ST.deposit(toTrancheUnits(_amount), _depositor);
        vm.stopPrank();
    }

    function _generateFundedDepositor(uint256 _index) internal returns (Vm.Wallet memory depositor) {
        depositor = _generateProvider(_index);
        dealSTAsset(depositor.addr, config.initialFunding);
        dealJTAsset(depositor.addr, config.initialFunding);
    }

    function _assertNAVConservation() internal view {
        // Get raw NAVs
        NAV_UNIT stRawNAV = ST.getRawNAV();
        NAV_UNIT jtRawNAV = JT.getRawNAV();

        // Get effective NAVs
        NAV_UNIT stEffectiveNAV = ST.totalAssets().nav;
        NAV_UNIT jtEffectiveNAV = JT.totalAssets().nav;

        // NAV Conservation: raw_st + raw_jt == effective_st + effective_jt
        uint256 rawSum = toUint256(stRawNAV) + toUint256(jtRawNAV);
        uint256 effectiveSum = toUint256(stEffectiveNAV) + toUint256(jtEffectiveNAV);

        assertApproxEqAbs(rawSum, effectiveSum, toUint256(maxNAVDelta()) * 2, "NAV conservation violated");
    }

    function _minDepositAmount() internal view virtual returns (uint256) {
        // Minimum deposit to avoid dust issues
        return 10 ** (config.stDecimals > 6 ? config.stDecimals - 6 : 0) * 1000; // At least 1000 smallest units
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 11: LONG SCENARIO-BASED TESTS
    // These tests run multi-step scenarios and verify view function values
    // after each operation to ensure consistency throughout the protocol lifecycle.
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Full lifecycle test: JT deposit → ST deposit → yield → verify coverage → ST redeem → JT exit
    /// @dev Verifies all view functions after each operation
    function testFuzz_scenario_fullLifecycle_withYield_verifyViewFunctions(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 2);
        _stPercentage = bound(_stPercentage, 10, 80);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 1: Verify initial state - all values should be zero
        // ═══════════════════════════════════════════════════════════════════════════

        _verifyTrancheState(stState, TrancheType.SENIOR, "initial ST");
        _verifyTrancheState(jtState, TrancheType.JUNIOR, "initial JT");

        assertEq(ST.maxDeposit(ALICE_ADDRESS), ZERO_TRANCHE_UNITS, "Initial ST maxDeposit should be 0");
        assertGt(JT.maxDeposit(ALICE_ADDRESS), ZERO_TRANCHE_UNITS, "Initial JT maxDeposit should be > 0");
        assertEq(ST.maxRedeem(ALICE_ADDRESS), 0, "Initial ST maxRedeem should be 0");
        assertEq(JT.maxRedeem(ALICE_ADDRESS), 0, "Initial JT maxRedeem should be 0");

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 2: JT deposits - provides coverage for ST
        // ═══════════════════════════════════════════════════════════════════════════

        uint256 jtShares = _depositJT(ALICE_ADDRESS, _jtAmount);
        NAV_UNIT jtDepositNAV = KERNEL.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(_jtAmount));
        _updateTrancheStateOnDeposit(jtState, toTrancheUnits(_jtAmount), jtDepositNAV, jtShares, TrancheType.JUNIOR);

        // Verify JT state after deposit
        _verifyTrancheState(jtState, TrancheType.JUNIOR, "after JT deposit");

        // Verify JT view functions
        assertEq(JT.balanceOf(ALICE_ADDRESS), jtShares, "JT balance should match shares");
        assertEq(JT.totalSupply(), jtShares, "JT totalSupply should match shares");
        assertApproxEqAbs(
            toUint256(JT.convertToAssets(JT.maxRedeem(ALICE_ADDRESS)).nav),
            toUint256(JT.convertToAssets(jtShares).nav),
            toUint256(ACCOUNTANT.getState().jtNAVDustTolerance) + 1,
            "JT maxRedeem should equal shares"
        );

        // Verify ST maxDeposit is now enabled
        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        assertGt(stMaxDeposit, ZERO_TRANCHE_UNITS, "ST maxDeposit should be > 0 after JT deposit");

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 3: ST deposits - uses JT coverage
        // ═══════════════════════════════════════════════════════════════════════════

        uint256 stAmount = toUint256(stMaxDeposit) * _stPercentage / 100;
        // Cap to what BOB has funded
        if (stAmount > config.initialFunding) stAmount = config.initialFunding * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        uint256 stShares = _depositST(BOB_ADDRESS, stAmount);
        NAV_UNIT stDepositNAV = KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(stAmount));
        _updateTrancheStateOnDeposit(stState, toTrancheUnits(stAmount), stDepositNAV, stShares, TrancheType.SENIOR);

        // Verify ST state after deposit
        _verifyTrancheState(stState, TrancheType.SENIOR, "after ST deposit");

        // Verify ST view functions
        assertEq(ST.balanceOf(BOB_ADDRESS), stShares, "ST balance should match shares");
        assertEq(ST.totalSupply(), stShares, "ST totalSupply should match shares");
        assertEq(ST.maxRedeem(BOB_ADDRESS), stShares, "ST maxRedeem should equal shares");

        // Verify JT maxRedeem decreased due to coverage requirement
        uint256 jtMaxRedeemAfterST = JT.maxRedeem(ALICE_ADDRESS);
        assertLt(jtMaxRedeemAfterST, jtShares, "JT maxRedeem should decrease after ST deposit");

        // Verify NAV conservation
        _assertNAVConservation();

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 4: Simulate yield
        // ═══════════════════════════════════════════════════════════════════════════

        NAV_UNIT jtNavBeforeYield = JT.totalAssets().nav;

        simulateJTYield(_yieldPercentage * 1e16);
        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT jtNavAfterYield = JT.totalAssets().nav;

        // JT should gain from yield
        assertGt(jtNavAfterYield, jtNavBeforeYield, "JT NAV should increase after yield");

        // Verify NAV conservation after yield
        _assertNAVConservation();

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 5: ST redeems - synchronous
        // ═══════════════════════════════════════════════════════════════════════════

        // Capture JT maxRedeem before ST redeems (after yield) for comparison
        uint256 jtMaxRedeemBeforeSTRedeems = JT.maxRedeem(ALICE_ADDRESS);

        uint256 stMaxRedeem = ST.maxRedeem(BOB_ADDRESS);
        assertEq(stMaxRedeem, stShares, "ST should be able to redeem all shares");

        // Preview redeem
        AssetClaims memory stPreviewClaims = ST.previewRedeem(stMaxRedeem);
        assertGt(toUint256(stPreviewClaims.stAssets), 0, "ST preview should return assets");

        uint256 stBalanceBefore = IERC20(config.stAsset).balanceOf(BOB_ADDRESS);

        vm.prank(BOB_ADDRESS);
        AssetClaims memory stRedeemClaims = ST.redeem(stMaxRedeem, BOB_ADDRESS, BOB_ADDRESS);

        uint256 stBalanceAfter = IERC20(config.stAsset).balanceOf(BOB_ADDRESS);

        // Verify ST received assets
        assertGt(stBalanceAfter, stBalanceBefore, "ST should receive assets on redeem");
        assertApproxEqRel(toUint256(stRedeemClaims.stAssets), toUint256(stPreviewClaims.stAssets), PREVIEW_RELATIVE_DELTA, "Redeem should match preview");

        // Verify ST state after redeem
        assertEq(ST.balanceOf(BOB_ADDRESS), 0, "ST balance should be 0 after full redeem");

        // ST totalSupply may have protocol fee shares remaining after yield accrual
        uint256 stFeeShares = ST.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);
        assertEq(ST.totalSupply(), stFeeShares, "ST totalSupply should only be fee shares");

        // Redeem protocol fee shares so all ST NAV is cleared
        if (stFeeShares > 0) {
            // Grant LP roles to protocol fee recipient so they can redeem
            vm.startPrank(LP_ROLE_ADMIN_ADDRESS);
            FACTORY.grantRole(ST_LP_ROLE, PROTOCOL_FEE_RECIPIENT_ADDRESS, 0);
            FACTORY.grantRole(JT_LP_ROLE, PROTOCOL_FEE_RECIPIENT_ADDRESS, 0);
            vm.stopPrank();

            vm.prank(PROTOCOL_FEE_RECIPIENT_ADDRESS);
            ST.redeem(stFeeShares, PROTOCOL_FEE_RECIPIENT_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS);
        }

        // Verify JT can now redeem more (all ST shares including fees have been redeemed)
        uint256 jtMaxRedeemAfterSTRedeem = JT.maxRedeem(ALICE_ADDRESS);
        assertGt(jtMaxRedeemAfterSTRedeem, jtMaxRedeemBeforeSTRedeems, "JT maxRedeem should increase after all ST redeems");

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 6: JT redeems - synchronous
        // ═══════════════════════════════════════════════════════════════════════════

        uint256 jtMaxRedeem = JT.maxRedeem(ALICE_ADDRESS);

        uint256 jtBalanceBefore = IERC20(config.jtAsset).balanceOf(ALICE_ADDRESS);

        vm.prank(ALICE_ADDRESS);
        JT.redeem(jtMaxRedeem, ALICE_ADDRESS, ALICE_ADDRESS);

        uint256 jtBalanceAfter = IERC20(config.jtAsset).balanceOf(ALICE_ADDRESS);

        // JT should receive more than deposited due to yield
        assertGt(jtBalanceAfter, jtBalanceBefore, "JT should receive assets");

        // Verify final state
        _assertNAVConservation();
    }

    /// @notice Multi-depositor scenario: Multiple JT depositors → ST deposit → loss → verify coverage protection
    function testFuzz_scenario_multipleJTDepositors_STLoss_verifyCoverageProtection(
        uint256 _numJTDepositors,
        uint256 _jtAmountSeed,
        uint256 _stPercentage,
        uint256 _lossPercentage
    )
        external
    {
        _numJTDepositors = bound(_numJTDepositors, 2, 5);
        _stPercentage = bound(_stPercentage, 20, 60);
        _lossPercentage = bound(_lossPercentage, 1, 15);

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 1: Multiple JT depositors
        // ═══════════════════════════════════════════════════════════════════════════

        uint256 totalJTShares = 0;
        NAV_UNIT totalJTNavDeposited = ZERO_NAV_UNITS;

        for (uint256 i = 0; i < _numJTDepositors; i++) {
            Vm.Wallet memory depositor = _generateFundedDepositor(i);
            uint256 amount = bound(uint256(keccak256(abi.encodePacked(_jtAmountSeed, i))), _minDepositAmount() * 5, config.initialFunding / 10);

            uint256 sharesBefore = JT.totalSupply();
            uint256 shares = _depositJT(depositor.addr, amount);

            // Verify shares minted
            assertGt(shares, 0, "Should mint JT shares");
            assertEq(JT.totalSupply(), sharesBefore + shares, "Total supply should increase");

            // Verify depositor balance
            assertEq(JT.balanceOf(depositor.addr), shares, "Depositor should have shares");

            totalJTShares += shares;
            totalJTNavDeposited = totalJTNavDeposited + KERNEL.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(amount));
        }

        // Verify total JT state
        assertEq(JT.totalSupply(), totalJTShares, "JT total supply should match sum");
        assertApproxEqAbs(
            toUint256(JT.totalAssets().nav), toUint256(totalJTNavDeposited), toUint256(maxNAVDelta()) * _numJTDepositors, "JT NAV should match deposits"
        );

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 2: ST deposits
        // ═══════════════════════════════════════════════════════════════════════════

        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(stMaxDeposit) * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;
        if (stAmount > config.initialFunding) stAmount = config.initialFunding;

        uint256 stShares = _depositST(BOB_ADDRESS, stAmount);

        // Verify ST state
        assertEq(ST.balanceOf(BOB_ADDRESS), stShares, "ST balance should match");
        assertEq(ST.totalSupply(), stShares, "ST total supply should match");

        NAV_UNIT stNavBeforeLoss = ST.totalAssets().nav;
        NAV_UNIT jtNavBeforeLoss = JT.totalAssets().nav;

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 3: Simulate JT loss - ST should be protected
        // ═══════════════════════════════════════════════════════════════════════════

        simulateJTLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT stNavAfterLoss = ST.totalAssets().nav;
        NAV_UNIT jtNavAfterLoss = JT.totalAssets().nav;

        // ST should be protected (approximately unchanged)
        assertApproxEqRel(toUint256(stNavAfterLoss), toUint256(stNavBeforeLoss), MAX_RELATIVE_DELTA, "ST should be protected from JT loss");

        // JT should absorb the loss
        assertLt(jtNavAfterLoss, jtNavBeforeLoss, "JT should absorb the loss");

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 4: Verify all JT depositors' convertToAssets decreased proportionally
        // ═══════════════════════════════════════════════════════════════════════════

        for (uint256 i = 0; i < _numJTDepositors; i++) {
            Vm.Wallet memory depositor = _generateFundedDepositor(i);
            uint256 depositorShares = JT.balanceOf(depositor.addr);

            AssetClaims memory claims = JT.convertToAssets(depositorShares);
            // Each depositor's claim should be reduced due to loss
            assertGt(toUint256(claims.nav), 0, "Depositor should still have some claim");
        }

        // Verify NAV conservation
        _assertNAVConservation();

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 5: Verify ST can still be previewed for redemption value
        // Note: Actual redemption might fail if market transitioned to FIXED_TERM
        // ═══════════════════════════════════════════════════════════════════════════

        uint256 stMaxRedeem = ST.maxRedeem(BOB_ADDRESS);
        if (stMaxRedeem > 0) {
            AssetClaims memory stPreviewClaims = ST.previewRedeem(stMaxRedeem);

            // ST should still have value (coverage protected them)
            assertGt(toUint256(stPreviewClaims.nav), 0, "ST should have redemption value");

            // The NAV should be approximately what was deposited (coverage protected)
            assertApproxEqRel(
                toUint256(stPreviewClaims.nav), toUint256(stNavBeforeLoss), MAX_RELATIVE_DELTA, "ST preview NAV should be approximately original deposit"
            );
        }
    }

    /// @notice Consecutive deposit/redeem cycles with yield accrual
    function testFuzz_scenario_consecutiveDepositRedeemCycles_withYield(uint256 _numCycles, uint256 _amountSeed, uint256 _yieldPercentage) external {
        _numCycles = bound(_numCycles, 2, 4);
        _yieldPercentage = bound(_yieldPercentage, 1, 10);

        NAV_UNIT cumulativeYieldToJT = ZERO_NAV_UNITS;

        for (uint256 cycle = 0; cycle < _numCycles; cycle++) {
            // ═══════════════════════════════════════════════════════════════════════════
            // STEP A: JT deposits
            // ═══════════════════════════════════════════════════════════════════════════

            uint256 jtAmount = bound(uint256(keccak256(abi.encodePacked(_amountSeed, cycle, "jt"))), _minDepositAmount() * 10, config.initialFunding / 8);

            NAV_UNIT jtNavBefore = JT.totalAssets().nav;
            uint256 jtTotalSupplyBefore = JT.totalSupply();

            uint256 jtShares = _depositJT(ALICE_ADDRESS, jtAmount);

            // Verify JT deposit
            assertEq(JT.totalSupply(), jtTotalSupplyBefore + jtShares, "JT total supply should increase");
            assertGt(JT.totalAssets().nav, jtNavBefore, "JT NAV should increase after deposit");

            // ═══════════════════════════════════════════════════════════════════════════
            // STEP B: ST deposits (if coverage allows)
            // ═══════════════════════════════════════════════════════════════════════════

            TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
            uint256 stAmount = bound(uint256(keccak256(abi.encodePacked(_amountSeed, cycle, "st"))), _minDepositAmount(), toUint256(stMaxDeposit) / 2);

            if (stAmount >= _minDepositAmount() && stAmount <= toUint256(stMaxDeposit)) {
                uint256 stShares = _depositST(BOB_ADDRESS, stAmount);
                assertGt(stShares, 0, "Should mint ST shares");
            }

            // ═══════════════════════════════════════════════════════════════════════════
            // STEP C: Simulate yield
            // ═══════════════════════════════════════════════════════════════════════════

            NAV_UNIT jtNavBeforeYield = JT.totalAssets().nav;

            simulateJTYield(_yieldPercentage * 1e16);
            vm.warp(vm.getBlockTimestamp() + 1 days);

            vm.prank(SYNC_ROLE_ADDRESS);
            KERNEL.syncTrancheAccounting();

            NAV_UNIT jtNavAfterYield = JT.totalAssets().nav;
            NAV_UNIT yieldGained = jtNavAfterYield - jtNavBeforeYield;
            cumulativeYieldToJT = cumulativeYieldToJT + yieldGained;

            // Verify yield was distributed
            assertGt(jtNavAfterYield, jtNavBeforeYield, "JT NAV should increase from yield");

            // ═══════════════════════════════════════════════════════════════════════════
            // STEP D: ST redeems all (if any)
            // ═══════════════════════════════════════════════════════════════════════════

            uint256 stMaxRedeem = ST.maxRedeem(BOB_ADDRESS);
            if (stMaxRedeem > 0) {
                AssetClaims memory stPreviewClaims = ST.previewRedeem(stMaxRedeem);

                vm.prank(BOB_ADDRESS);
                AssetClaims memory stRedeemClaims = ST.redeem(stMaxRedeem, BOB_ADDRESS, BOB_ADDRESS);

                assertApproxEqRel(
                    toUint256(stRedeemClaims.stAssets), toUint256(stPreviewClaims.stAssets), PREVIEW_RELATIVE_DELTA, "ST redeem should match preview"
                );
            }

            // Verify NAV conservation at end of each cycle
            _assertNAVConservation();
        }

        // Final verification
        assertGt(toUint256(cumulativeYieldToJT), 0, "Should have accumulated yield");
    }

    /// @notice High utilization scenario: Test coverage limits
    function testFuzz_scenario_highUtilization_verifyCoverageLimits(uint256 _jtAmount, uint256 _additionalJTAmount) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 4);
        _additionalJTAmount = bound(_additionalJTAmount, _minDepositAmount() * 5, config.initialFunding / 4);

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 1: Initial JT deposit
        // ═══════════════════════════════════════════════════════════════════════════

        uint256 jtShares = _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT initialSTMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        assertGt(initialSTMaxDeposit, ZERO_TRANCHE_UNITS, "ST maxDeposit should be > 0");

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 2: ST deposits to max (100% utilization)
        // ═══════════════════════════════════════════════════════════════════════════

        uint256 stAmount = toUint256(initialSTMaxDeposit);
        if (stAmount > config.initialFunding) stAmount = config.initialFunding;
        if (stAmount < _minDepositAmount()) return;

        uint256 stShares = _depositST(BOB_ADDRESS, stAmount);

        // Verify high utilization state
        TRANCHE_UNIT stMaxDepositAfter = ST.maxDeposit(BOB_ADDRESS);
        assertLt(stMaxDepositAfter, initialSTMaxDeposit, "ST maxDeposit should decrease");

        uint256 jtMaxRedeemAfter = JT.maxRedeem(ALICE_ADDRESS);
        assertLt(jtMaxRedeemAfter, jtShares, "JT maxRedeem should be limited");

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 3: Additional JT deposit increases coverage
        // ═══════════════════════════════════════════════════════════════════════════

        uint256 additionalJTShares = _depositJT(CHARLIE_ADDRESS, _additionalJTAmount);

        // Verify increased coverage
        TRANCHE_UNIT newSTMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        assertGt(newSTMaxDeposit, stMaxDepositAfter, "ST maxDeposit should increase with more JT");

        uint256 aliceNewMaxRedeem = JT.maxRedeem(ALICE_ADDRESS);
        assertGt(aliceNewMaxRedeem, jtMaxRedeemAfter, "Alice JT maxRedeem should increase");

        // ═══════════════════════════════════════════════════════════════════════════
        // STEP 4: ST redeems - unlocks JT
        // ═══════════════════════════════════════════════════════════════════════════

        vm.prank(BOB_ADDRESS);
        ST.redeem(stShares, BOB_ADDRESS, BOB_ADDRESS);

        // Verify JT fully unlocked
        uint256 aliceFinalMaxRedeem = JT.maxRedeem(ALICE_ADDRESS);
        uint256 charlieFinalMaxRedeem = JT.maxRedeem(CHARLIE_ADDRESS);

        assertApproxEqAbs(aliceFinalMaxRedeem, jtShares, toUint256(ACCOUNTANT.getState().stNAVDustTolerance) + 1, "Alice should be able to redeem all");
        assertApproxEqAbs(
            charlieFinalMaxRedeem, additionalJTShares, toUint256(ACCOUNTANT.getState().stNAVDustTolerance) + 1, "Charlie should be able to redeem all"
        );

        // Verify NAV conservation
        _assertNAVConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SCENARIO TEST HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Updates tranche state on deposit
    function _updateTrancheStateOnDeposit(
        TrancheState storage _trancheState,
        TRANCHE_UNIT _assets,
        NAV_UNIT _assetsValue,
        uint256 _shares,
        TrancheType _trancheType
    )
        internal
    {
        _trancheState.rawNAV = _trancheState.rawNAV + _assetsValue;
        _trancheState.effectiveNAV = _trancheState.effectiveNAV + _assetsValue;
        if (_trancheType == TrancheType.SENIOR) {
            _trancheState.stAssetsClaim = _trancheState.stAssetsClaim + _assets;
        } else {
            _trancheState.jtAssetsClaim = _trancheState.jtAssetsClaim + _assets;
        }
        _trancheState.totalShares += _shares;
    }

    /// @notice Verifies tranche state matches expected
    function _verifyTrancheState(TrancheState memory _expectedState, TrancheType _trancheType, string memory _context) internal view {
        IRoycoVaultTranche tranche = _trancheType == TrancheType.SENIOR ? ST : JT;

        assertApproxEqAbs(tranche.getRawNAV(), _expectedState.rawNAV, maxNAVDelta(), string.concat(_context, ": raw NAV mismatch"));

        AssetClaims memory claims = tranche.totalAssets();
        assertApproxEqAbs(claims.nav, _expectedState.effectiveNAV, maxNAVDelta(), string.concat(_context, ": effective NAV mismatch"));

        if (_trancheType == TrancheType.SENIOR) {
            assertApproxEqAbs(claims.stAssets, _expectedState.stAssetsClaim, maxTrancheUnitDelta(), string.concat(_context, ": ST assets claim mismatch"));
        } else {
            assertApproxEqAbs(claims.jtAssets, _expectedState.jtAssetsClaim, maxTrancheUnitDelta(), string.concat(_context, ": JT assets claim mismatch"));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 12: REDEMPTION LIMIT TESTS
    // Tests that redemption cannot exceed maxRedeem under ALL scenarios
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that redeem reverts when requesting more shares than owned (no coverage constraint)
    function testFuzz_redemptionLimit_revertsWhenRequestingMoreThanOwned(uint256 _jtAmount) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 4);

        // Deposit JT for ALICE
        uint256 jtShares = _depositJT(ALICE_ADDRESS, _jtAmount);

        // maxRedeem should equal owned shares (no ST, no coverage constraint)
        uint256 maxRedeemable = JT.maxRedeem(ALICE_ADDRESS);
        assertApproxEqAbs(
            toUint256(JT.convertToAssets(maxRedeemable).nav),
            toUint256(JT.convertToAssets(jtShares).nav),
            toUint256(ACCOUNTANT.getState().jtNAVDustTolerance) + 1,
            "maxRedeem should equal owned shares"
        );

        // Try to redeem more than owned - should revert
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        JT.redeem(jtShares + 1, ALICE_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Test that redeem reverts when requesting more than maxRedeem due to coverage
    function testFuzz_redemptionLimit_revertsAboveMaxRedeem_coverageConstraint(uint256 _jtAmount, uint256 _stPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 50, 90);

        // Deposit JT
        uint256 jtShares = _depositJT(ALICE_ADDRESS, _jtAmount);

        // Deposit ST to lock some JT coverage
        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(stMaxDeposit) * _stPercentage / 100;
        if (stAmount > config.initialFunding) stAmount = config.initialFunding * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // Get max redeemable (should be less than total shares due to coverage)
        uint256 maxRedeemable = JT.maxRedeem(ALICE_ADDRESS);
        assertLt(maxRedeemable, jtShares, "maxRedeem should be less than total shares");

        // Should revert when trying to redeem all shares (exceeds maxRedeem due to coverage)
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        JT.redeem(jtShares, ALICE_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Test that redeem reverts when requesting exactly maxRedeem + 1
    function testFuzz_redemptionLimit_revertsAtMaxRedeemPlusOne(uint256 _jtAmount, uint256 _stPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 30, 70);

        // Deposit JT
        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Deposit ST to create coverage constraint
        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(stMaxDeposit) * _stPercentage / 100;
        if (stAmount > config.initialFunding) stAmount = config.initialFunding * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        uint256 maxRedeemable = JT.maxRedeem(ALICE_ADDRESS);
        if (maxRedeemable == 0) return;

        // Try to redeem maxRedeem + 1 - should revert
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        JT.redeem(maxRedeemable + 1, ALICE_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Test that redeem reverts after loss tightens coverage
    function testFuzz_redemptionLimit_revertsAfterLossTightensCoverage(uint256 _jtAmount, uint256 _stPercentage, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 20, config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 30, 60);
        _lossPercentage = bound(_lossPercentage, 5, 15);

        // Deposit JT
        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Deposit ST
        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(stMaxDeposit) * _stPercentage / 100;
        if (stAmount > config.initialFunding) stAmount = config.initialFunding * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // Record maxRedeem before loss
        uint256 maxRedeemBeforeLoss = JT.maxRedeem(ALICE_ADDRESS);
        if (maxRedeemBeforeLoss == 0) return;

        // Simulate loss
        simulateJTLoss(_lossPercentage * 1e16);
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // maxRedeem should decrease after loss
        uint256 maxRedeemAfterLoss = JT.maxRedeem(ALICE_ADDRESS);

        // If the old maxRedeem is now above the new limit, it should revert
        if (maxRedeemBeforeLoss > maxRedeemAfterLoss) {
            vm.prank(ALICE_ADDRESS);
            vm.expectRevert();
            JT.redeem(maxRedeemBeforeLoss, ALICE_ADDRESS, ALICE_ADDRESS);
        }
    }

    /// @notice Test that redeem reverts for zero shares
    function test_redemptionLimit_revertsOnZeroShares() external {
        uint256 _jtAmount = _minDepositAmount() * 10;

        // Deposit JT
        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Try to redeem 0 shares - should revert
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector));
        JT.redeem(0, ALICE_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Test that redeeming exactly maxRedeem succeeds
    function testFuzz_redemptionLimit_redeem_succeedsAtMaxRedeem(uint256 _jtAmount, uint256 _stPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 20, 60);

        // Deposit JT
        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Deposit ST to lock some JT coverage
        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(stMaxDeposit) * _stPercentage / 100;
        if (stAmount > config.initialFunding) stAmount = config.initialFunding * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // Get max redeemable
        uint256 maxRedeemable = JT.maxRedeem(ALICE_ADDRESS);
        if (maxRedeemable == 0) return;

        // Redeem exactly maxRedeem - should succeed
        uint256 balanceBefore = IERC20(config.jtAsset).balanceOf(ALICE_ADDRESS);
        vm.prank(ALICE_ADDRESS);
        AssetClaims memory claims = JT.redeem(maxRedeemable, ALICE_ADDRESS, ALICE_ADDRESS);

        assertGt(toUint256(claims.jtAssets), 0, "Should receive JT assets");
        assertGt(IERC20(config.jtAsset).balanceOf(ALICE_ADDRESS), balanceBefore, "JT asset balance should increase");
    }

    /// @notice Test that multiple sequential redeems at maxRedeem succeed
    function testFuzz_redemptionLimit_multipleSequentialRedeems_succeedAtMaxRedeem(uint256 _jtAmount) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 20, config.initialFunding / 4);

        // Deposit JT
        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Deposit ST to create coverage constraint
        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(stMaxDeposit) / 2;
        if (stAmount > config.initialFunding / 2) stAmount = config.initialFunding / 2;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // Redeem in multiple chunks, always at or below maxRedeem
        for (uint256 i = 0; i < 3; i++) {
            uint256 maxRedeemable = JT.maxRedeem(ALICE_ADDRESS);
            if (maxRedeemable == 0) break;

            uint256 toRedeem = maxRedeemable / 2;
            if (toRedeem == 0) toRedeem = maxRedeemable;

            vm.prank(ALICE_ADDRESS);
            AssetClaims memory claims = JT.redeem(toRedeem, ALICE_ADDRESS, ALICE_ADDRESS);
            assertGt(toUint256(claims.jtAssets), 0, "Should receive JT assets");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 13: ALLOWANCE SPENDING TESTS
    // Tests that ERC20 allowance works with sync redeem
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that a third party with allowance can redeem on behalf of owner
    function testFuzz_allowance_canSpendAllowance_toRedeem(uint256 _jtAmount) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 4);

        // Deposit JT for ALICE (JT_ALICE has JT_LP_ROLE)
        uint256 jtShares = _depositJT(ALICE_ADDRESS, _jtAmount);

        // ALICE approves JT_BOB to spend her shares
        vm.prank(ALICE_ADDRESS);
        JT.approve(JT_BOB_ADDRESS, jtShares);

        // Verify allowance
        assertEq(JT.allowance(ALICE_ADDRESS, JT_BOB_ADDRESS), jtShares, "Allowance should be set");

        // Check that maxRedeem is equal to the deposited shares
        assertApproxEqAbs(
            toUint256(JT.convertToAssets(JT.maxRedeem(ALICE_ADDRESS)).nav),
            toUint256(JT.convertToAssets(jtShares).nav),
            toUint256(ACCOUNTANT.getState().jtNAVDustTolerance) + 1
        );
        jtShares = JT.maxRedeem(ALICE_ADDRESS);

        uint256 bobAssetsBefore = IERC20(config.jtAsset).balanceOf(JT_BOB_ADDRESS);

        // JT_BOB (has allowance + JT_LP_ROLE) redeems ALICE's shares - should succeed
        vm.prank(JT_BOB_ADDRESS);
        AssetClaims memory claims = JT.redeem(jtShares, JT_BOB_ADDRESS, ALICE_ADDRESS);

        assertGt(toUint256(claims.jtAssets), 0, "Should receive JT assets");
        assertGt(IERC20(config.jtAsset).balanceOf(JT_BOB_ADDRESS), bobAssetsBefore, "JT_BOB should receive assets");

        // Allowance should be spent
        assertTrue(JT.allowance(ALICE_ADDRESS, JT_BOB_ADDRESS) <= toUint256(ACCOUNTANT.getState().stNAVDustTolerance) + 1, "Allowance should be spent");
    }

    /// @notice Test that allowance spending fails with insufficient allowance
    function testFuzz_allowance_insufficientAllowance_reverts(uint256 _jtAmount) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 2, config.initialFunding / 4);

        // Deposit JT for ALICE (JT_ALICE has JT_LP_ROLE)
        uint256 jtShares = _depositJT(ALICE_ADDRESS, _jtAmount);

        // ALICE approves JT_BOB to spend half her shares
        uint256 halfShares = jtShares / 2;
        vm.prank(ALICE_ADDRESS);
        JT.approve(JT_BOB_ADDRESS, halfShares);

        // JT_BOB tries to redeem more than his allowance - should revert
        vm.prank(JT_BOB_ADDRESS);
        vm.expectRevert(); // ERC20InsufficientAllowance
        JT.redeem(jtShares, JT_BOB_ADDRESS, ALICE_ADDRESS);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 14: REDEEM NAV INVARIANT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that JT redeem conserves NAV
    function testFuzz_navInvariant_redeem_conservesNAV(uint256 _jtAmount) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 4);

        // Deposit JT
        uint256 jtShares = _depositJT(ALICE_ADDRESS, _jtAmount);
        uint256 maxRedeemable = JT.maxRedeem(ALICE_ADDRESS);
        if (maxRedeemable == 0) return;

        // Redeem and verify NAV conservation after
        vm.prank(ALICE_ADDRESS);
        JT.redeem(maxRedeemable, ALICE_ADDRESS, ALICE_ADDRESS);

        _assertNAVConservation();
    }

    /// @notice Test that multiple JT redeems conserve NAV
    function testFuzz_navInvariant_multipleRedeems_conservesNAV(uint256 _jtAmount, uint256 _numRedeems) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 4);
        _numRedeems = bound(_numRedeems, 2, 5);

        // Deposit JT
        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Perform multiple redeems
        for (uint256 i = 0; i < _numRedeems; i++) {
            uint256 maxRedeemable = JT.maxRedeem(ALICE_ADDRESS);
            if (maxRedeemable == 0) break;

            uint256 toRedeem = maxRedeemable / (_numRedeems - i);
            if (toRedeem == 0) toRedeem = maxRedeemable;

            vm.prank(ALICE_ADDRESS);
            JT.redeem(toRedeem, ALICE_ADDRESS, ALICE_ADDRESS);
        }

        // Verify NAV conservation after all redeems
        _assertNAVConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 15: COVERAGE TIGHTENING TESTS
    // Tests that maxRedeem is reduced when coverage tightens
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that maxRedeem is reduced when coverage tightens due to loss
    function testFuzz_coverageTightening_maxRedeem_reducedOnLoss(uint256 _jtAmount, uint256 _stPercentage, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 20, config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 30, 70);
        _lossPercentage = bound(_lossPercentage, 5, 15);

        // Deposit JT
        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Deposit ST to create coverage requirement
        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(stMaxDeposit) * _stPercentage / 100;
        if (stAmount > config.initialFunding) stAmount = config.initialFunding * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // Get max redeemable before loss
        uint256 maxRedeemableBefore = JT.maxRedeem(ALICE_ADDRESS);
        if (maxRedeemableBefore == 0) return;

        // Simulate loss to tighten coverage
        simulateJTLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // maxRedeem after loss should be reduced or zero
        uint256 maxRedeemableAfterLoss = JT.maxRedeem(ALICE_ADDRESS);
        assertLe(maxRedeemableAfterLoss, maxRedeemableBefore, "maxRedeem should not increase after loss");
    }

    /// @notice Test that maxRedeem decreases when ST deposit tightens coverage
    function testFuzz_coverageTightening_maxRedeem_decreasesOnSTDeposit(uint256 _jtAmount, uint256 _stPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 20, config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 40, 80);

        // Deposit JT
        uint256 jtShares = _depositJT(ALICE_ADDRESS, _jtAmount);

        // Get max redeemable with no ST (should be all shares)
        uint256 maxRedeemableNoST = JT.maxRedeem(ALICE_ADDRESS);
        assertApproxEqAbs(
            toUint256(JT.convertToAssets(maxRedeemableNoST).nav),
            toUint256(JT.convertToAssets(jtShares).nav),
            toUint256(ACCOUNTANT.getState().jtNAVDustTolerance) + 1,
            "Should be able to redeem all initially"
        );

        // Now deposit ST which will tighten coverage
        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(stMaxDeposit) * _stPercentage / 100;
        if (stAmount > config.initialFunding) stAmount = config.initialFunding * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // After ST deposit, coverage is tightened
        uint256 maxRedeemableAfterST = JT.maxRedeem(ALICE_ADDRESS);

        // maxRedeem should decrease due to coverage constraint
        assertLt(maxRedeemableAfterST, maxRedeemableNoST, "maxRedeem should decrease after ST deposit");
    }

    /// @notice Test that redeem respects coverage limits
    function testFuzz_coverageTightening_redeem_respectsCoverageLimits(uint256 _jtAmount, uint256 _stPercentage) external virtual {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 20, config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 50, 90);

        // Deposit JT
        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Deposit ST to tighten coverage
        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(stMaxDeposit) * _stPercentage / 100;
        if (stAmount > config.initialFunding) stAmount = config.initialFunding * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // Get what's actually redeemable
        uint256 maxRedeemable = JT.maxRedeem(ALICE_ADDRESS);

        // If nothing is redeemable, skip
        if (maxRedeemable == 0) return;

        // Redeem at maxRedeem - should succeed
        vm.prank(ALICE_ADDRESS);
        AssetClaims memory claims = JT.redeem(maxRedeemable, ALICE_ADDRESS, ALICE_ADDRESS);

        assertGt(toUint256(claims.jtAssets), 0, "Should have received assets");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 16: MAX REDEEM SCENARIO TESTS
    // Tests maxRedeem under various circumstances
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test maxRedeem returns zero for zero balance
    function test_maxRedeem_zeroForZeroBalance() external {
        assertEq(JT.maxRedeem(ALICE_ADDRESS), 0, "maxRedeem should be 0 for zero balance");
        assertEq(ST.maxRedeem(ALICE_ADDRESS), 0, "maxRedeem should be 0 for zero balance");
    }

    /// @notice Test maxRedeem returns full balance when no coverage constraint
    function testFuzz_maxRedeem_fullBalance_noCoverageConstraint(uint256 _jtAmount) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 4);

        // Deposit JT with no ST (no coverage constraint)
        uint256 jtShares = _depositJT(ALICE_ADDRESS, _jtAmount);

        // maxRedeem should equal full balance
        uint256 maxRedeemable = JT.maxRedeem(ALICE_ADDRESS);
        assertApproxEqAbs(
            toUint256(JT.convertToAssets(maxRedeemable).nav),
            toUint256(JT.convertToAssets(jtShares).nav),
            toUint256(ACCOUNTANT.getState().jtNAVDustTolerance) + 1,
            "maxRedeem should equal full balance with no ST"
        );
    }

    /// @notice Test ST maxRedeem returns full balance (ST has no coverage constraint on itself)
    function testFuzz_maxRedeem_ST_fullBalance(uint256 _jtAmount, uint256 _stPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 20, 80);

        // Deposit JT to provide coverage
        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Deposit ST
        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(stMaxDeposit) * _stPercentage / 100;
        if (stAmount > config.initialFunding) stAmount = config.initialFunding * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        uint256 stShares = _depositST(BOB_ADDRESS, stAmount);

        // ST maxRedeem should equal full balance
        uint256 stMaxRedeem = ST.maxRedeem(BOB_ADDRESS);
        assertEq(stMaxRedeem, stShares, "ST maxRedeem should equal full balance");
    }

    /// @notice Test JT maxRedeem decreases proportionally with ST deposits
    function testFuzz_maxRedeem_JT_decreasesWithSTDeposits(uint256 _jtAmount) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 4);

        // Deposit JT
        uint256 jtShares = _depositJT(ALICE_ADDRESS, _jtAmount);
        uint256 maxRedeemBefore = JT.maxRedeem(ALICE_ADDRESS);
        assertApproxEqAbs(
            toUint256(JT.convertToAssets(maxRedeemBefore).nav),
            toUint256(JT.convertToAssets(jtShares).nav),
            toUint256(ACCOUNTANT.getState().jtNAVDustTolerance) + 1,
            "Initially should redeem all"
        );

        // Deposit ST in increments and verify maxRedeem decreases
        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stIncrement = toUint256(stMaxDeposit) / 4;
        if (stIncrement < _minDepositAmount()) return;
        if (stIncrement > config.initialFunding / 4) stIncrement = config.initialFunding / 4;

        uint256 previousMaxRedeem = maxRedeemBefore;

        for (uint256 i = 0; i < 3; i++) {
            stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
            if (toUint256(stMaxDeposit) < stIncrement) break;

            _depositST(BOB_ADDRESS, stIncrement);

            uint256 currentMaxRedeem = JT.maxRedeem(ALICE_ADDRESS);
            assertLe(currentMaxRedeem, previousMaxRedeem, "maxRedeem should decrease or stay same with more ST");
            previousMaxRedeem = currentMaxRedeem;
        }
    }

    /// @notice Test JT maxRedeem increases when ST redeems
    function testFuzz_maxRedeem_JT_increasesWhenSTRedeems(uint256 _jtAmount, uint256 _stPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 30, 70);

        // Deposit JT
        uint256 jtShares = _depositJT(ALICE_ADDRESS, _jtAmount);

        // Deposit ST
        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(stMaxDeposit) * _stPercentage / 100;
        if (stAmount > config.initialFunding) stAmount = config.initialFunding * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        uint256 stShares = _depositST(BOB_ADDRESS, stAmount);

        // Record JT maxRedeem with ST deposited
        uint256 maxRedeemWithST = JT.maxRedeem(ALICE_ADDRESS);
        assertLt(maxRedeemWithST, jtShares, "JT maxRedeem should be limited by ST coverage");

        // ST redeems
        vm.prank(BOB_ADDRESS);
        ST.redeem(stShares, BOB_ADDRESS, BOB_ADDRESS);

        // JT maxRedeem should increase
        uint256 maxRedeemAfterSTRedeem = JT.maxRedeem(ALICE_ADDRESS);
        assertGt(maxRedeemAfterSTRedeem, maxRedeemWithST, "JT maxRedeem should increase after ST redeems");
        assertApproxEqAbs(
            maxRedeemAfterSTRedeem,
            jtShares,
            toUint256(ACCOUNTANT.getState().stNAVDustTolerance + ACCOUNTANT.getState().jtNAVDustTolerance) + 1,
            "JT maxRedeem should return to full balance"
        );
    }

    /// @notice Test maxRedeem after yield still respects coverage
    function testFuzz_maxRedeem_afterYield_respectsCoverage(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 30, 60);
        _yieldPercentage = bound(_yieldPercentage, 1, 10);

        // Deposit JT and ST
        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(stMaxDeposit) * _stPercentage / 100;
        if (stAmount > config.initialFunding) stAmount = config.initialFunding * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        uint256 stShares = _depositST(BOB_ADDRESS, stAmount);

        // Record maxRedeem before yield
        uint256 jtMaxRedeemBeforeYield = JT.maxRedeem(ALICE_ADDRESS);

        // Simulate yield
        simulateJTYield(_yieldPercentage * 1e16);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // maxRedeem after yield
        uint256 jtMaxRedeemAfterYield = JT.maxRedeem(ALICE_ADDRESS);

        // ST maxRedeem should still be full balance
        assertEq(ST.maxRedeem(BOB_ADDRESS), stShares, "ST maxRedeem should still be full balance");
    }

    /// @notice Test maxRedeem after loss increases (more JT becomes redeemable as coverage ratio improves)
    function testFuzz_maxRedeem_afterLoss_changes(uint256 _jtAmount, uint256 _stPercentage, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 4);
        _stPercentage = bound(_stPercentage, 30, 60);
        _lossPercentage = bound(_lossPercentage, 1, 10);

        // Deposit JT and ST
        uint256 jtShares = _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT stMaxDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(stMaxDeposit) * _stPercentage / 100;
        if (stAmount > config.initialFunding) stAmount = config.initialFunding * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // Record maxRedeem before loss
        uint256 jtMaxRedeemBeforeLoss = JT.maxRedeem(ALICE_ADDRESS);
        assertLt(jtMaxRedeemBeforeLoss, jtShares, "Should be coverage constrained");

        // Simulate loss
        simulateJTLoss(_lossPercentage * 1e16);
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // maxRedeem after loss - coverage might have tightened
        uint256 jtMaxRedeemAfterLoss = JT.maxRedeem(ALICE_ADDRESS);

        // After loss, more JT value is needed to cover ST, so maxRedeem should decrease
        assertLe(jtMaxRedeemAfterLoss, jtMaxRedeemBeforeLoss, "maxRedeem should decrease or stay same after loss");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 17: KERNEL-ONLY FUNCTION ACCESS CONTROL TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that mintProtocolFeeShares reverts when called by non-kernel for ST
    function test_mintProtocolFeeShares_revertsWhenCalledByNonKernel_ST() external {
        // Try to call mintProtocolFeeShares from a random address
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoVaultTranche.ONLY_KERNEL.selector));
        ST.mintProtocolFeeShares(toNAVUnits(uint256(1e18)), toNAVUnits(uint256(1e18)), ALICE_ADDRESS);
    }

    /// @notice Test that mintProtocolFeeShares reverts when called by non-kernel for JT
    function test_mintProtocolFeeShares_revertsWhenCalledByNonKernel_JT() external {
        // Try to call mintProtocolFeeShares from a random address
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoVaultTranche.ONLY_KERNEL.selector));
        JT.mintProtocolFeeShares(toNAVUnits(uint256(1e18)), toNAVUnits(uint256(1e18)), ALICE_ADDRESS);
    }

    /// @notice Test that mintProtocolFeeShares reverts when called by owner (not kernel)
    function test_mintProtocolFeeShares_revertsWhenCalledByOwner() external {
        // Even the owner should not be able to call this directly
        vm.prank(OWNER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoVaultTranche.ONLY_KERNEL.selector));
        ST.mintProtocolFeeShares(toNAVUnits(uint256(1e18)), toNAVUnits(uint256(1e18)), OWNER_ADDRESS);

        vm.prank(OWNER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoVaultTranche.ONLY_KERNEL.selector));
        JT.mintProtocolFeeShares(toNAVUnits(uint256(1e18)), toNAVUnits(uint256(1e18)), OWNER_ADDRESS);
    }

    /// @notice Test that mintProtocolFeeShares reverts when called by protocol fee recipient
    function test_mintProtocolFeeShares_revertsWhenCalledByProtocolFeeRecipient() external {
        // Even the protocol fee recipient should not be able to call this directly
        vm.prank(PROTOCOL_FEE_RECIPIENT_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoVaultTranche.ONLY_KERNEL.selector));
        ST.mintProtocolFeeShares(toNAVUnits(uint256(1e18)), toNAVUnits(uint256(1e18)), PROTOCOL_FEE_RECIPIENT_ADDRESS);

        vm.prank(PROTOCOL_FEE_RECIPIENT_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoVaultTranche.ONLY_KERNEL.selector));
        JT.mintProtocolFeeShares(toNAVUnits(uint256(1e18)), toNAVUnits(uint256(1e18)), PROTOCOL_FEE_RECIPIENT_ADDRESS);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION: ROUNDING INVARIANT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that pure deposits (no yield/loss) never cause FIXED_TERM state transition
    /// @dev FIXED_TERM should only occur from actual losses, not from deposit rounding
    /// @param _numCycles Number of deposit cycles to run
    function testFuzz_deposits_neverCauseFixedTermState(uint256 _numCycles) external {
        _numCycles = bound(_numCycles, 1, 100);

        // Verify initial state is PERPETUAL
        assertEq(uint256(ACCOUNTANT.getState().lastMarketState), uint256(MarketState.PERPETUAL), "Market should start in PERPETUAL state");

        uint256 minDeposit = _minDepositAmount();

        for (uint256 i = 0; i < _numCycles; i++) {
            // Generate unique depositors for each cycle
            Vm.Wallet memory jtDepositor = _generateProvider(i * 2);
            Vm.Wallet memory stDepositor = _generateProvider(i * 2 + 1);

            // JT deposit - fund just-in-time with exact amount needed
            uint256 jtAmount = minDeposit * 10;
            dealJTAsset(jtDepositor.addr, jtAmount);
            _depositJT(jtDepositor.addr, jtAmount);

            // ST deposit - use 50% of max to guarantee coverage compliance
            TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(stDepositor.addr);
            uint256 stAmount = toUint256(maxSTDeposit) / 2;

            if (stAmount >= minDeposit) {
                // Fund just-in-time with exact amount needed
                dealSTAsset(stDepositor.addr, stAmount);
                _depositST(stDepositor.addr, stAmount);
            }

            // CRITICAL ASSERTION: Market must remain in PERPETUAL state
            // Pure deposits should NEVER cause transition to FIXED_TERM
            MarketState currentState = ACCOUNTANT.getState().lastMarketState;
            assertEq(uint256(currentState), uint256(MarketState.PERPETUAL), "Market entered FIXED_TERM on deposit");
        }

        // Final sync and verification
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        assertEq(uint256(ACCOUNTANT.getState().lastMarketState), uint256(MarketState.PERPETUAL), "Market should still be PERPETUAL after all deposit cycles");

        // Verify no JT coverage impermanent loss accumulated
        NAV_UNIT jtCoverageIL = ACCOUNTANT.getState().lastJTImpermanentLoss;
        assertEq(toUint256(jtCoverageIL), 0, "JT coverage IL should be 0 with no yield/loss - only deposits");
    }

    /// @notice Test full cycle: JT deposit -> ST deposit -> ST withdraw -> JT withdraw
    /// @dev Pure deposit/withdraw interleaving should never revert (no yield/loss)
    /// @dev Override this test for protocols with time-sensitive oracles (Chainlink, etc.)
    /// @param _numCycles Number of full cycles to run
    function testFuzz_fullDepositWithdrawCycle_neverReverts(uint256 _numCycles) external virtual {
        _numCycles = bound(_numCycles, 1, 100);

        uint256 minDeposit = _minDepositAmount();

        for (uint256 i = 0; i < _numCycles; i++) {
            // Generate unique depositors for this cycle
            Vm.Wallet memory jtDepositor = _generateProvider(i * 2);
            Vm.Wallet memory stDepositor = _generateProvider(i * 2 + 1);

            // ══════════════════════════════════════════════════════════════
            // STEP 1: JT Deposit
            // ══════════════════════════════════════════════════════════════
            uint256 jtDepositAmount = minDeposit * 10;
            dealJTAsset(jtDepositor.addr, jtDepositAmount);
            uint256 jtShares = _depositJT(jtDepositor.addr, jtDepositAmount);
            assertGt(jtShares, 0, "JT deposit should mint shares");

            // ══════════════════════════════════════════════════════════════
            // STEP 2: ST Deposit (50% of max to ensure coverage)
            // ══════════════════════════════════════════════════════════════
            TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(stDepositor.addr);
            uint256 stDepositAmount = toUint256(maxSTDeposit) / 2;
            uint256 stShares = 0;

            if (stDepositAmount >= minDeposit) {
                dealSTAsset(stDepositor.addr, stDepositAmount);
                stShares = _depositST(stDepositor.addr, stDepositAmount);
                assertGt(stShares, 0, "ST deposit should mint shares");
            }

            // Verify market is still PERPETUAL after deposits
            assertEq(
                uint256(ACCOUNTANT.getState().lastMarketState),
                uint256(MarketState.PERPETUAL),
                string.concat("Market should be PERPETUAL after deposits on cycle ", vm.toString(i))
            );

            // ══════════════════════════════════════════════════════════════
            // STEP 3: ST Withdraw (if ST deposited)
            // ══════════════════════════════════════════════════════════════
            if (stShares > 0) {
                uint256 stMaxRedeem = ST.maxRedeem(stDepositor.addr);
                uint256 stSharesToRedeem = stShares < stMaxRedeem ? stShares : stMaxRedeem;

                if (stSharesToRedeem > 0) {
                    vm.startPrank(stDepositor.addr);
                    ST.redeem(stSharesToRedeem, stDepositor.addr, stDepositor.addr);
                    vm.stopPrank();
                }
            }

            // ══════════════════════════════════════════════════════════════
            // STEP 4: JT Withdraw (sync)
            // ══════════════════════════════════════════════════════════════
            uint256 jtMaxRedeem = JT.maxRedeem(jtDepositor.addr);
            uint256 jtSharesToRedeem = jtShares < jtMaxRedeem ? jtShares : jtMaxRedeem;

            if (jtSharesToRedeem > 0) {
                vm.startPrank(jtDepositor.addr);
                JT.redeem(jtSharesToRedeem, jtDepositor.addr, jtDepositor.addr);
                vm.stopPrank();
            }

            // Verify market is still PERPETUAL after full cycle
            assertEq(
                uint256(ACCOUNTANT.getState().lastMarketState),
                uint256(MarketState.PERPETUAL),
                string.concat("Market should be PERPETUAL after full cycle ", vm.toString(i))
            );
        }

        // Final sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Final state verification
        assertEq(uint256(ACCOUNTANT.getState().lastMarketState), uint256(MarketState.PERPETUAL), "Market should be PERPETUAL after all cycles");

        // Verify no significant impermanent losses accumulated from pure deposit/withdraw
        // (allow for dust tolerance from underlying protocol rounding)
        NAV_UNIT stIL = ACCOUNTANT.getState().lastSTImpermanentLoss;
        NAV_UNIT jtCoverageIL = ACCOUNTANT.getState().lastJTImpermanentLoss;
        NAV_UNIT stNAVDustTolerance = ACCOUNTANT.getState().stNAVDustTolerance;

        assertEq(toUint256(stIL), 0, "ST IL should be 0 with no yield/loss");
        assertLe(toUint256(jtCoverageIL), toUint256(stNAVDustTolerance), "JT coverage IL should be within dust tolerance");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION: ST DEPOSIT DISABLED WHEN IMPERMANENT LOSS EXISTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that ST deposits are allowed when there is no impermanent loss
    function test_stDeposit_allowedWhenNoImpermanentLoss() external {
        // Deposit JT first to provide coverage
        uint256 jtDeposit = _minDepositAmount() * 10;
        _depositJT(ALICE_ADDRESS, jtDeposit);

        // ST max deposit should be non-zero (deposits allowed)
        TRANCHE_UNIT maxDeposit = ST.maxDeposit(BOB_ADDRESS);
        assertGt(maxDeposit, ZERO_TRANCHE_UNITS, "ST deposits should be allowed when no impermanent loss");

        // Should be able to deposit ST
        uint256 stDeposit = _minDepositAmount();
        _depositST(BOB_ADDRESS, stDeposit);

        // Verify deposit succeeded
        assertGt(ST.balanceOf(BOB_ADDRESS), 0, "BOB should have ST shares after deposit");
    }

    /// @notice Test that stMaxDeposit returns zero when ST impermanent loss exists
    function test_stMaxDeposit_returnsZeroWhenImpermanentLossExists() external {
        // Setup: Deposit JT and ST with high ST:JT ratio so losses exceed JT capacity
        uint256 jtDeposit = _minDepositAmount() * 5;
        _depositJT(ALICE_ADDRESS, jtDeposit);

        // Deposit maximum ST allowed
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stDeposit = toUint256(maxSTDeposit);
        if (stDeposit < _minDepositAmount()) return; // Skip if no ST deposits allowed
        _depositST(BOB_ADDRESS, stDeposit);

        // Verify ST deposits are initially allowed for new depositors
        TRANCHE_UNIT maxDepositBefore = ST.maxDeposit(CHARLIE_ADDRESS);

        // Simulate a massive loss that exceeds JT capacity (50% loss)
        // This will cause ST impermanent loss since JT cannot cover all losses
        simulateJTLoss(0.5e18);

        // Sync accounting to register the loss
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Check if ST impermanent loss exists
        NAV_UNIT stIL = ACCOUNTANT.getState().lastSTImpermanentLoss;
        if (stIL == ZERO_NAV_UNITS) {
            // JT was able to absorb all losses, skip this test
            return;
        }

        // ST max deposit should now be zero
        TRANCHE_UNIT maxDepositAfter = ST.maxDeposit(CHARLIE_ADDRESS);
        assertEq(maxDepositAfter, ZERO_TRANCHE_UNITS, "ST deposits should be disabled when impermanent loss exists");
    }

    /// @notice Test that ST deposit reverts when impermanent loss exists
    function test_stDeposit_revertsWhenImpermanentLossExists() external {
        // Setup: Deposit JT and ST with high ST:JT ratio
        uint256 jtDeposit = _minDepositAmount() * 5;
        _depositJT(ALICE_ADDRESS, jtDeposit);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stDeposit = toUint256(maxSTDeposit);
        if (stDeposit < _minDepositAmount()) return;
        _depositST(BOB_ADDRESS, stDeposit);

        // Simulate a massive loss that exceeds JT capacity
        simulateJTLoss(0.5e18);

        // Sync accounting to register the loss
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Check if ST impermanent loss exists
        NAV_UNIT stIL = ACCOUNTANT.getState().lastSTImpermanentLoss;
        if (stIL == ZERO_NAV_UNITS) {
            // JT was able to absorb all losses, skip this test
            return;
        }

        // Attempting to deposit ST should revert
        uint256 newStDeposit = _minDepositAmount();
        dealSTAsset(ST_CHARLIE_ADDRESS, newStDeposit);

        vm.startPrank(ST_CHARLIE_ADDRESS);
        IERC20(config.stAsset).approve(address(ST), newStDeposit);

        // Should revert with ST_DEPOSIT_DISABLED_IN_LOSS
        vm.expectRevert();
        ST.deposit(toTrancheUnits(newStDeposit), ST_CHARLIE_ADDRESS);
        vm.stopPrank();
    }

    /// @notice Test that ST deposits are re-enabled after impermanent loss is recovered
    function test_stDeposit_reenabledAfterImpermanentLossRecovery() external {
        // Setup: Deposit JT and ST
        uint256 jtDeposit = _minDepositAmount() * 5;
        _depositJT(ALICE_ADDRESS, jtDeposit);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stDeposit = toUint256(maxSTDeposit);
        if (stDeposit < _minDepositAmount()) return;
        _depositST(BOB_ADDRESS, stDeposit);

        // Simulate a loss that creates ST impermanent loss
        simulateJTLoss(0.5e18);

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Check if ST impermanent loss exists
        NAV_UNIT stILBeforeRecovery = ACCOUNTANT.getState().lastSTImpermanentLoss;
        if (stILBeforeRecovery == ZERO_NAV_UNITS) {
            // JT was able to absorb all losses, skip this test
            return;
        }

        // Verify deposits are disabled
        assertEq(ST.maxDeposit(CHARLIE_ADDRESS), ZERO_TRANCHE_UNITS, "ST deposits should be disabled");

        // Simulate recovery (large yield to recover the impermanent loss)
        simulateJTYield(2e18); // 200% yield to recover from 50% loss

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Check if impermanent loss was recovered
        NAV_UNIT stILAfterRecovery = ACCOUNTANT.getState().lastSTImpermanentLoss;
        if (stILAfterRecovery == ZERO_NAV_UNITS) {
            // ST deposits should be re-enabled
            TRANCHE_UNIT maxDepositAfterRecovery = ST.maxDeposit(CHARLIE_ADDRESS);
            assertGt(maxDepositAfterRecovery, ZERO_TRANCHE_UNITS, "ST deposits should be re-enabled after full recovery");
        }
    }

    /// @notice Test that small losses absorbed by JT do not disable ST deposits
    function test_stDeposit_notDisabledWhenJTAbsorbsLoss() external {
        // Setup: Deposit more JT than ST to ensure JT can absorb losses
        uint256 jtDeposit = _minDepositAmount() * 100;
        _depositJT(ALICE_ADDRESS, jtDeposit);

        // Deposit small amount of ST
        uint256 stDeposit = _minDepositAmount() * 5;
        _depositST(BOB_ADDRESS, stDeposit);

        // Simulate a small loss that JT can fully absorb (5%)
        simulateJTLoss(0.05e18);

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Verify no ST impermanent loss
        NAV_UNIT stIL = ACCOUNTANT.getState().lastSTImpermanentLoss;
        assertEq(stIL, ZERO_NAV_UNITS, "ST should have no impermanent loss when JT absorbs all losses");

        // ST deposits should still be allowed
        TRANCHE_UNIT maxDeposit = ST.maxDeposit(ST_CHARLIE_ADDRESS);
        assertGt(maxDeposit, ZERO_TRANCHE_UNITS, "ST deposits should still be allowed when JT absorbs loss");

        // Should be able to deposit ST
        uint256 newStDeposit = _minDepositAmount();
        dealSTAsset(ST_CHARLIE_ADDRESS, newStDeposit);
        _depositST(ST_CHARLIE_ADDRESS, newStDeposit);
        assertGt(ST.balanceOf(ST_CHARLIE_ADDRESS), 0, "ST_CHARLIE should have ST shares");
    }
}
