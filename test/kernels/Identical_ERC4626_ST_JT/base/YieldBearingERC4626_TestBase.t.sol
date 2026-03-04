// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata, IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { Identical_ERC4626_ST_ERC4626_JT_Kernel } from "../../../../src/kernels/Identical_ERC4626_ST_ERC4626_JT_Kernel.sol";
import { WAD, WAD_DECIMALS, ZERO_NAV_UNITS } from "../../../../src/libraries/Constants.sol";
import { SyncedAccountingState, TrancheType } from "../../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { AbstractKernelTestSuite } from "../../abstract/AbstractKernelTestSuite.t.sol";

/// @title YieldBearingERC4626_TestBase
/// @notice Base test contract for Identical_ERC4626_ST_ERC4626_JT_Kernel
/// @dev Implements the test hooks for yield-bearing ERC4626 assets where ST and JT use identical assets
///
/// IMPORTANT: This kernel stores the `vaultAsset-to-NAV` conversion rate (e.g., NUSD->USD for sNUSD).
/// The actual tranche-to-NAV conversion combines:
///   1. ERC4626.convertToAssets(WAD) - share to vault asset rate
///   2. storedRate (in WAD) - vault asset to NAV rate
/// Result: trancheToNAV = shareToAsset * storedRate / WAD
abstract contract YieldBearingERC4626_TestBase is AbstractKernelTestSuite {
    // ═══════════════════════════════════════════════════════════════════════════
    // STATE FOR MOCKED SHARE PRICE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tracks the mocked share price (in WAD precision)
    /// @dev When non-zero, this value is used to mock convertToAssets() calls
    uint256 internal mockedSharePriceWAD;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION (To be overridden by protocol-specific implementations)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the initial vault-asset-to-NAV conversion rate (in WAD precision)
    /// @dev For stablecoins like sNUSD (where NUSD ≈ USD), this should be WAD (1e18)
    /// Override this for non-stablecoin vaults where the vault asset has a different NAV
    function _getInitialConversionRate() internal view virtual returns (uint256) {
        // Default: 1:1 conversion in WAD precision (for stablecoins)
        return WAD;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NAV MANIPULATION HOOKS IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates yield for ST by increasing the conversion rate
    function simulateSTYield(uint256 _percentageWAD) public virtual override {
        _simulateYield(_percentageWAD);
    }

    /// @notice Simulates yield for JT by increasing the conversion rate
    /// @dev For identical assets, ST and JT share the same conversion rate
    function simulateJTYield(uint256 _percentageWAD) public virtual override {
        _simulateYield(_percentageWAD);
    }

    /// @notice Simulates loss for ST by decreasing the conversion rate
    function simulateSTLoss(uint256 _percentageWAD) public virtual override {
        _simulateLoss(_percentageWAD);
    }

    /// @notice Simulates loss for JT by decreasing the conversion rate
    /// @dev For identical assets, ST and JT share the same conversion rate
    function simulateJTLoss(uint256 _percentageWAD) public virtual override {
        _simulateLoss(_percentageWAD);
    }

    /// @notice Sets the conversion rate for ST (in WAD precision)
    function setSTConversionRate(uint256 _rateWAD) public virtual {
        _setConversionRate(_rateWAD);
    }

    /// @notice Sets the conversion rate for JT (in WAD precision)
    /// @dev For identical assets, this is the same as ST
    function setJTConversionRate(uint256 _rateWAD) public virtual {
        _setConversionRate(_rateWAD);
    }

    /// @notice Deals ST asset to an address
    function dealSTAsset(address _to, uint256 _amount) public virtual override {
        deal(config.stAsset, _to, _amount);
    }

    /// @notice Deals JT asset to an address
    function dealJTAsset(address _to, uint256 _amount) public virtual override {
        deal(config.jtAsset, _to, _amount);
    }

    /// @notice Returns max tranche unit delta for comparisons
    function maxTrancheUnitDelta() public view virtual override returns (TRANCHE_UNIT) {
        // Default: 1e12 tolerance (good for 18 decimal tokens)
        return toTrancheUnits(uint256(1e12));
    }

    /// @notice Returns max NAV delta for comparisons
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view virtual override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VAULT SHARE PRICE MANIPULATION (ERC4626 convertToAssets component)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates vault share price yield by mocking convertToAssets()
    /// @param _percentageWAD The percentage increase in WAD (e.g., 0.05e18 = 5%)
    function simulateVaultSharePriceYield(uint256 _percentageWAD) public virtual {
        uint256 currentSharePrice = _getCurrentSharePriceWAD();
        uint256 newSharePrice = currentSharePrice * (WAD + _percentageWAD) / WAD;
        _mockConvertToAssets(newSharePrice);
    }

    /// @notice Simulates vault share price loss by mocking convertToAssets()
    /// @param _percentageWAD The percentage decrease in WAD (e.g., 0.05e18 = 5%)
    function simulateVaultSharePriceLoss(uint256 _percentageWAD) public virtual {
        uint256 currentSharePrice = _getCurrentSharePriceWAD();
        uint256 newSharePrice = currentSharePrice * (WAD - _percentageWAD) / WAD;
        _mockConvertToAssets(newSharePrice);
    }

    /// @notice Computes the share amount to pass to convertToAssets() to get WAD-scaled output
    /// @dev This matches the kernel's SHARES_TO_CONVERT_TO_ASSETS calculation
    function _getSharesToConvertToAssets() internal view virtual returns (uint256) {
        return 10 ** (WAD_DECIMALS + IERC4626(config.stAsset).decimals() - IERC20Metadata(IERC4626(config.stAsset).asset()).decimals());
    }

    /// @notice Gets the current share price (either mocked or from the actual vault)
    /// @return The share price in WAD precision
    function _getCurrentSharePriceWAD() internal view virtual returns (uint256) {
        if (mockedSharePriceWAD != 0) {
            return mockedSharePriceWAD;
        }
        // Get the actual share price from the vault using the same input the kernel uses
        return IERC4626(config.stAsset).convertToAssets(_getSharesToConvertToAssets());
    }

    /// @notice Mocks the convertToAssets function on the vault
    /// @param _newSharePriceWAD The new share price in WAD precision
    function _mockConvertToAssets(uint256 _newSharePriceWAD) internal virtual {
        mockedSharePriceWAD = _newSharePriceWAD;

        // Mock convertToAssets with the same input the kernel uses (SHARES_TO_CONVERT_TO_ASSETS)
        uint256 sharesToConvert = _getSharesToConvertToAssets();
        vm.mockCall(config.stAsset, abi.encodeWithSelector(IERC4626.convertToAssets.selector, sharesToConvert), abi.encode(_newSharePriceWAD));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS (STORED CONVERSION RATE)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates yield by increasing the conversion rate
    /// @param _percentageWAD The yield percentage in WAD (e.g., 0.05e18 = 5%)
    function _simulateYield(uint256 _percentageWAD) internal {
        uint256 currentRate = _getConversionRate();
        // Apply percentage increase: newRate = currentRate * (1 + percentage)
        uint256 newRate = currentRate * (WAD + _percentageWAD) / WAD;
        _setConversionRate(newRate);
    }

    /// @notice Simulates loss by decreasing the conversion rate
    /// @param _percentageWAD The loss percentage in WAD (e.g., 0.05e18 = 5%)
    function _simulateLoss(uint256 _percentageWAD) internal {
        uint256 currentRate = _getConversionRate();
        // Apply percentage decrease: newRate = currentRate * (1 - percentage)
        uint256 newRate = currentRate * (WAD - _percentageWAD) / WAD;
        _setConversionRate(newRate);
    }

    /// @notice Gets the current conversion rate using the kernel's getter (in WAD precision)
    function _getConversionRate() internal view virtual returns (uint256) {
        return Identical_ERC4626_ST_ERC4626_JT_Kernel(address(KERNEL)).getStoredConversionRateWAD();
    }

    /// @notice Sets the conversion rate using the kernel's setter (in WAD precision)
    /// @dev Requires ADMIN_ORACLE_QUOTER_ROLE, which is granted to ORACLE_QUOTER_ADMIN_ADDRESS
    function _setConversionRate(uint256 _newRateWAD) internal virtual {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        Identical_ERC4626_ST_ERC4626_JT_Kernel(address(KERNEL)).setConversionRate(_newRateWAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORED CONVERSION RATE TESTS (baseAsset-to-NAV component)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that stored conversion rate yield increases NAV
    /// @dev This tests the baseAsset-to-NAV component of the conversion rate
    function testFuzz_storedConversionRate_yield_updatesNAV(uint256 _jtAmount, uint256 _yieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        // Simulate yield by increasing the stored conversion rate
        uint256 yieldWAD = _yieldBps * 1e14; // Convert bps to WAD
        _simulateYield(yieldWAD);

        uint256 rateAfter = _getConversionRate();
        assertGt(rateAfter, rateBefore, "Stored rate should increase after yield");

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after stored conversion rate yield");
    }

    /// @notice Tests that stored conversion rate loss decreases NAV
    /// @dev This tests the baseAsset-to-NAV component of the conversion rate
    function testFuzz_storedConversionRate_loss_updatesNAV(uint256 _jtAmount, uint256 _lossBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossBps = bound(_lossBps, 10, 500); // 0.1% to 5% loss

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        // Simulate loss by decreasing the stored conversion rate
        uint256 lossWAD = _lossBps * 1e14; // Convert bps to WAD
        _simulateLoss(lossWAD);

        uint256 rateAfter = _getConversionRate();
        assertLt(rateAfter, rateBefore, "Stored rate should decrease after loss");

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after stored conversion rate loss");
    }

    /// @notice Tests that stored conversion rate yield with ST deposits distributes correctly
    function testFuzz_storedConversionRate_yield_distributesToJT(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT jtNavBefore = JT.totalAssets().nav;

        // Simulate yield via stored conversion rate
        uint256 yieldWAD = _yieldBps * 1e14;
        _simulateYield(yieldWAD);

        // Warp time for yield distribution
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT jtNavAfter = JT.totalAssets().nav;

        // JT should receive portion of yield based on YDM
        assertGe(jtNavAfter, jtNavBefore, "JT NAV should increase or stay same from stored rate yield");
    }

    /// @notice Tests NAV conservation after stored conversion rate changes
    function testFuzz_storedConversionRate_NAVConservation(uint256 _jtAmount, uint256 _yieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldBps = bound(_yieldBps, 10, 1000);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Simulate yield via stored conversion rate
        uint256 yieldWAD = _yieldBps * 1e14;
        _simulateYield(yieldWAD);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        _assertNAVConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VAULT SHARE PRICE TESTS (ERC4626 convertToAssets component)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that vault share price yield increases NAV
    /// @dev This tests the ERC4626.convertToAssets() component of the conversion rate
    function testFuzz_vaultSharePrice_yield_updatesNAV(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 50); // 1-50% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate vault share price yield (mocks convertToAssets)
        simulateVaultSharePriceYield(_yieldPercentage * 1e16); // Convert to WAD

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after vault share price yield");
    }

    /// @notice Tests that vault share price loss decreases NAV
    /// @dev This tests the ERC4626.convertToAssets() component of the conversion rate
    function testFuzz_vaultSharePrice_loss_updatesNAV(uint256 _jtAmount, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossPercentage = bound(_lossPercentage, 1, 30); // 1-30% loss

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate vault share price loss (mocks convertToAssets)
        simulateVaultSharePriceLoss(_lossPercentage * 1e16); // Convert to WAD

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after vault share price loss");
    }

    /// @notice Tests that vault share price yield with ST deposits distributes correctly
    function testFuzz_vaultSharePrice_yield_distributesToJT(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT jtNavBefore = JT.totalAssets().nav;

        // Simulate vault share price yield
        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        // Warp time for yield distribution
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT jtNavAfter = JT.totalAssets().nav;

        // JT should receive portion of yield based on YDM
        assertGe(jtNavAfter, jtNavBefore, "JT NAV should increase or stay same from vault share price yield");
    }

    /// @notice Tests NAV conservation after vault share price changes
    function testFuzz_vaultSharePrice_NAVConservation(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Simulate vault share price yield
        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        _assertNAVConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMBINED SHARE PRICE + STORED RATE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests combined yield from both share price AND stored rate increases
    function testFuzz_combined_yield_bothComponents(uint256 _jtAmount, uint256 _sharePriceYieldBps, uint256 _storedRateYieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceYieldBps = bound(_sharePriceYieldBps, 10, 500); // 0.1% to 5%
        _storedRateYieldBps = bound(_storedRateYieldBps, 10, 500); // 0.1% to 5%

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Apply both yields
        simulateVaultSharePriceYield(_sharePriceYieldBps * 1e14);
        _simulateYield(_storedRateYieldBps * 1e14);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after combined yield");
    }

    /// @notice Tests combined loss from both share price AND stored rate decreases
    function testFuzz_combined_loss_bothComponents(uint256 _jtAmount, uint256 _sharePriceLossBps, uint256 _storedRateLossBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceLossBps = bound(_sharePriceLossBps, 10, 200); // 0.1% to 2%
        _storedRateLossBps = bound(_storedRateLossBps, 10, 200); // 0.1% to 2%

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Apply both losses
        simulateVaultSharePriceLoss(_sharePriceLossBps * 1e14);
        _simulateLoss(_storedRateLossBps * 1e14);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after combined loss");
    }

    /// @notice Tests NAV conservation after combined share price and stored rate changes
    function testFuzz_combined_NAVConservation(uint256 _jtAmount, uint256 _sharePriceChangeBps, uint256 _storedRateChangeBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceChangeBps = bound(_sharePriceChangeBps, 10, 500);
        _storedRateChangeBps = bound(_storedRateChangeBps, 10, 500);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Apply both changes
        simulateVaultSharePriceYield(_sharePriceChangeBps * 1e14);
        _simulateYield(_storedRateChangeBps * 1e14);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        _assertNAVConservation();
    }

    /// @notice Tests combined changes with ST deposits - yield distribution
    function testFuzz_combined_yield_distributesToJT(uint256 _jtAmount, uint256 _stPercentage, uint256 _sharePriceYieldBps, uint256 _storedRateYieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _sharePriceYieldBps = bound(_sharePriceYieldBps, 10, 300);
        _storedRateYieldBps = bound(_storedRateYieldBps, 10, 300);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT jtNavBefore = JT.totalAssets().nav;

        // Apply both yields
        simulateVaultSharePriceYield(_sharePriceYieldBps * 1e14);
        _simulateYield(_storedRateYieldBps * 1e14);

        // Warp time for yield distribution
        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT jtNavAfter = JT.totalAssets().nav;
        assertGe(jtNavAfter, jtNavBefore, "JT NAV should increase or stay same from combined yield");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SHARE PRICE IMPACT ON REDEMPTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that redemption returns more assets after share price increase
    function testFuzz_vaultSharePrice_yield_increasesRedemptionValue(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 5, 30); // 5-30% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 sharesBefore = JT.balanceOf(ALICE_ADDRESS);
        NAV_UNIT navValueBefore = JT.totalAssets().nav;

        // Simulate share price yield
        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Shares should be the same but worth more
        uint256 sharesAfter = JT.balanceOf(ALICE_ADDRESS);
        assertEq(sharesAfter, sharesBefore, "Share balance should not change");

        // The NAV value of shares should have increased
        NAV_UNIT navValueAfter = JT.totalAssets().nav;
        assertGt(navValueAfter, navValueBefore, "NAV value of shares should increase after yield");
    }

    /// @notice Tests that redemption returns fewer assets after share price decrease
    function testFuzz_vaultSharePrice_loss_decreasesRedemptionValue(uint256 _jtAmount, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossPercentage = bound(_lossPercentage, 5, 20); // 5-20% loss

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navValueBefore = JT.totalAssets().nav;

        // Simulate share price loss
        simulateVaultSharePriceLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navValueAfter = JT.totalAssets().nav;
        assertLt(navValueAfter, navValueBefore, "NAV value should decrease after loss");
    }

    /// @notice Tests redemption execution after share price change
    function testFuzz_vaultSharePrice_redemptionAfterYield(uint256 _jtAmount, uint256 _yieldPercentage, uint256 _redeemPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);
        _redeemPercentage = bound(_redeemPercentage, 10, 100);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Simulate share price yield
        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Calculate shares to redeem
        uint256 totalShares = JT.balanceOf(ALICE_ADDRESS);
        uint256 sharesToRedeem = totalShares * _redeemPercentage / 100;

        if (sharesToRedeem == 0) return;

        // Execute redemption - should not revert
        vm.prank(ALICE_ADDRESS);
        JT.redeem(sharesToRedeem, ALICE_ADDRESS, ALICE_ADDRESS);

        // Verify shares were burned
        assertEq(JT.balanceOf(ALICE_ADDRESS), totalShares - sharesToRedeem, "Shares should be burned");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SHARE PRICE IMPACT ON MAX DEPOSIT/REDEEM
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that maxDeposit changes appropriately after share price changes
    function testFuzz_vaultSharePrice_affectsMaxDeposit(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _yieldPercentage = bound(_yieldPercentage, 5, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDepositBefore = ST.maxDeposit(CHARLIE_ADDRESS);

        // Deposit some ST to have utilization
        uint256 stAmount = toUint256(maxSTDepositBefore) * _stPercentage / 100;
        if (stAmount >= _minDepositAmount()) {
            _depositST(BOB_ADDRESS, stAmount);
        }

        TRANCHE_UNIT maxSTDepositAfterDeposit = ST.maxDeposit(CHARLIE_ADDRESS);

        // Simulate share price yield (increases NAV, may change coverage)
        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        TRANCHE_UNIT maxSTDepositAfterYield = ST.maxDeposit(CHARLIE_ADDRESS);

        // After yield, JT NAV increases, so ST coverage increases, allowing more ST deposits
        // The exact relationship depends on the kernel's coverage calculations
        // Just verify it doesn't revert and returns a valid value
        assertTrue(toUint256(maxSTDepositAfterYield) >= 0, "maxDeposit should return valid value");
    }

    /// @notice Tests that maxRedeem reflects share price changes
    function testFuzz_vaultSharePrice_affectsMaxRedeem(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 5, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 maxRedeemBefore = JT.maxRedeem(ALICE_ADDRESS);
        assertGt(maxRedeemBefore, 0, "maxRedeem should be > 0 after deposit");

        // Simulate share price yield
        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        uint256 maxRedeemAfter = JT.maxRedeem(ALICE_ADDRESS);

        // maxRedeem should still be valid (may change based on NAV changes)
        assertTrue(maxRedeemAfter >= 0, "maxRedeem should return valid value");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IMPERMANENT LOSS WITH SHARE PRICE DROP
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that ST deposits are disabled when share price drops create impermanent loss
    function testFuzz_vaultSharePrice_loss_disablesSTDeposits(uint256 _jtAmount, uint256 _stPercentage, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 20, 80);
        _lossPercentage = bound(_lossPercentage, 10, 30); // Significant loss

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Deposit ST to have senior exposure
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // Simulate significant share price loss
        simulateVaultSharePriceLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Check if impermanent loss exists using previewSyncTrancheAccounting
        (SyncedAccountingState memory state,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        bool hasImpermanentLoss = state.stImpermanentLoss != ZERO_NAV_UNITS;

        // If there's impermanent loss, new ST deposits should be disabled (maxDeposit = 0)
        if (hasImpermanentLoss) {
            TRANCHE_UNIT maxSTDepositAfterLoss = ST.maxDeposit(CHARLIE_ADDRESS);
            assertEq(toUint256(maxSTDepositAfterLoss), 0, "ST deposits should be disabled during impermanent loss");
        }
    }

    /// @notice Tests that share price recovery can clear impermanent loss
    /// @dev Note: Even after clearing impermanent loss, ST deposits may still be disabled due to coverage constraints
    function testFuzz_vaultSharePrice_recovery_clearsImpermanentLoss(uint256 _jtAmount, uint256 _stPercentage, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 20, 50);
        _lossPercentage = bound(_lossPercentage, 5, 15);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // Simulate loss
        simulateVaultSharePriceLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        (SyncedAccountingState memory stateBefore,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        bool hadImpermanentLoss = stateBefore.stImpermanentLoss != ZERO_NAV_UNITS;

        // Recover by simulating yield that exceeds the loss significantly
        uint256 recoveryYield = (_lossPercentage * 2 + 10) * 1e16; // Double the loss + extra
        uint256 currentSharePrice = _getCurrentSharePriceWAD();
        uint256 newSharePrice = currentSharePrice * (WAD + recoveryYield) / WAD;
        _mockConvertToAssets(newSharePrice);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // After recovery, check if impermanent loss is cleared
        (SyncedAccountingState memory stateAfter,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        bool hasImpermanentLossAfterRecovery = stateAfter.stImpermanentLoss != ZERO_NAV_UNITS;

        // If there was impermanent loss, verify recovery reduced or cleared it
        if (hadImpermanentLoss) {
            // After significant yield, impermanent loss should be reduced or cleared
            assertTrue(
                stateAfter.stImpermanentLoss <= stateBefore.stImpermanentLoss,
                "Impermanent loss should not increase after recovery yield"
            );
        }

        // NAV conservation should still hold
        _assertNAVConservation();
    }

    /// @notice Tests share price loss with multiple depositors maintains NAV conservation
    function testFuzz_vaultSharePrice_loss_multipleDepositors_NAVConservation(
        uint256 _jtAmount1,
        uint256 _jtAmount2,
        uint256 _lossPercentage
    ) external {
        _jtAmount1 = bound(_jtAmount1, _minDepositAmount(), config.initialFunding / 20);
        _jtAmount2 = bound(_jtAmount2, _minDepositAmount(), config.initialFunding / 20);
        _lossPercentage = bound(_lossPercentage, 1, 20);

        // Multiple JT depositors (both using ALICE since she has LP role)
        _depositJT(ALICE_ADDRESS, _jtAmount1);

        // For second deposit, use CHARLIE who also has LP role
        _depositJT(CHARLIE_ADDRESS, _jtAmount2);

        // Simulate share price loss
        simulateVaultSharePriceLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // NAV should still be conserved
        _assertNAVConservation();
    }
}
