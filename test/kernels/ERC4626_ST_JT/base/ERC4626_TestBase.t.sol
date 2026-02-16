// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { ERC4626_ST_ERC4626_JT_InKindAssets_Kernel } from "../../../../src/kernels/ERC4626_ST_ERC4626_JT_InKindAssets_Kernel.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";

import { AbstractKernelTestSuite } from "../../abstract/AbstractKernelTestSuite.t.sol";

/// @title ERC4626_TestBase
/// @notice Base test contract for ERC4626_ST_ERC4626_JT_InKindAssets_Kernel
/// @dev Implements the test hooks for ERC4626 vaults where ST and JT deploy into ERC4626 vaults
///
/// This kernel deploys tranche assets into ERC4626 vaults. The NAV is computed from the vault's
/// share price via convertToAssets(). Yield/loss simulation is done by mocking convertToAssets().
abstract contract ERC4626_TestBase is AbstractKernelTestSuite {
    // ═══════════════════════════════════════════════════════════════════════════
    // STATE FOR MOCKED SHARE PRICES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tracks the mocked ST vault share price
    uint256 internal mockedSTSharePrice;

    /// @notice Tracks the mocked JT vault share price
    uint256 internal mockedJTSharePrice;

    /// @dev ERC7201 storage slot for ERC4626KernelState (from ERC4626KernelStorageLib)
    bytes32 private constant ERC4626_KERNEL_STORAGE_SLOT = 0x31dcae1a6c8e7be3177d6c56be6f186dd189c19bdd7d7f4820a1be934a634800;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION (To be overridden by protocol-specific implementations)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the ST vault address
    function _getSTVault() internal view virtual returns (address);

    /// @notice Returns the JT vault address
    function _getJTVault() internal view virtual returns (address);

    /// @notice Returns the JT redemption delay
    function _getJTRedemptionDelay() internal view virtual override returns (uint24) {
        return 7 days;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NAV MANIPULATION HOOKS IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates yield for ST by donating assets to the vault
    /// @dev This increases totalAssets without minting shares, which is how real yield works
    function simulateSTYield(uint256 _percentageWAD) public virtual override {
        address vault = _getSTVault();
        uint256 totalAssets = IERC4626(vault).totalAssets();
        uint256 yieldAmount = totalAssets * _percentageWAD / WAD;
        if (yieldAmount == 0) return;

        // Donate assets directly to the vault (not via deposit)
        dealSTAsset(address(this), yieldAmount);
        IERC20(config.stAsset).transfer(vault, yieldAmount);
    }

    /// @notice Simulates yield for JT by donating assets to the vault
    /// @dev This increases totalAssets without minting shares, which is how real yield works
    function simulateJTYield(uint256 _percentageWAD) public virtual override {
        address vault = _getJTVault();
        uint256 totalAssets = IERC4626(vault).totalAssets();
        uint256 yieldAmount = totalAssets * _percentageWAD / WAD;
        if (yieldAmount == 0) return;

        // Donate assets directly to the vault (not via deposit)
        dealJTAsset(address(this), yieldAmount);
        IERC20(config.jtAsset).transfer(vault, yieldAmount);
    }

    /// @notice Simulates loss for ST by mocking totalAssets to a lower value
    /// @dev Loss simulation requires mocking since we can't remove assets from the vault
    function simulateSTLoss(uint256 _percentageWAD) public virtual override {
        address vault = _getSTVault();
        uint256 totalAssets = IERC4626(vault).totalAssets();
        uint256 newTotalAssets = totalAssets * (WAD - _percentageWAD) / WAD;
        vm.mockCall(vault, abi.encodeWithSelector(IERC4626.totalAssets.selector), abi.encode(newTotalAssets));
    }

    /// @notice Simulates loss for JT by mocking totalAssets to a lower value
    /// @dev Loss simulation requires mocking since we can't remove assets from the vault
    function simulateJTLoss(uint256 _percentageWAD) public virtual override {
        address vault = _getJTVault();
        uint256 totalAssets = IERC4626(vault).totalAssets();
        uint256 newTotalAssets = totalAssets * (WAD - _percentageWAD) / WAD;
        vm.mockCall(vault, abi.encodeWithSelector(IERC4626.totalAssets.selector), abi.encode(newTotalAssets));
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
    // SHARE PRICE HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the current ST vault share price
    function _getSTSharePrice() internal view returns (uint256) {
        if (mockedSTSharePrice != 0) {
            return mockedSTSharePrice;
        }
        return IERC4626(_getSTVault()).convertToAssets(1e18);
    }

    /// @notice Gets the current JT vault share price
    function _getJTSharePrice() internal view returns (uint256) {
        if (mockedJTSharePrice != 0) {
            return mockedJTSharePrice;
        }
        return IERC4626(_getJTVault()).convertToAssets(1e18);
    }

    /// @notice Mocks the ST vault's convertToAssets to return scaled value for kernel's ST shares
    /// @dev Reads kernel's internal $.stOwnedShares via vm.load to get exact shares amount
    function _mockSTConvertToAssets(uint256 _newSharePrice) internal {
        mockedSTSharePrice = _newSharePrice;
        address vault = _getSTVault();

        // Read kernel's internal stOwnedShares from storage (slot 0 of ERC4626KernelState)
        uint256 stOwnedShares = uint256(vm.load(address(KERNEL), ERC4626_KERNEL_STORAGE_SLOT));

        if (stOwnedShares == 0) return;

        // Calculate what the new assets value should be at the new share price
        // assets = shares * sharePrice / 1e18
        uint256 newAssetsValue = stOwnedShares * _newSharePrice / 1e18;

        // Mock convertToAssets with the exact calldata (selector + shares amount)
        vm.mockCall(vault, abi.encodeWithSelector(IERC4626.convertToAssets.selector, stOwnedShares), abi.encode(newAssetsValue));
    }

    /// @notice Mocks the JT vault's convertToAssets to return scaled value for kernel's JT shares
    /// @dev Reads kernel's internal $.jtOwnedShares via vm.load to get exact shares amount
    function _mockJTConvertToAssets(uint256 _newSharePrice) internal {
        mockedJTSharePrice = _newSharePrice;
        address vault = _getJTVault();

        // Read kernel's internal jtOwnedShares from storage (slot 1 of ERC4626KernelState)
        bytes32 jtSharesSlot = bytes32(uint256(ERC4626_KERNEL_STORAGE_SLOT) + 1);
        uint256 jtOwnedShares = uint256(vm.load(address(KERNEL), jtSharesSlot));

        if (jtOwnedShares == 0) return;

        // Calculate what the new assets value should be at the new share price
        // assets = shares * sharePrice / 1e18
        uint256 newAssetsValue = jtOwnedShares * _newSharePrice / 1e18;

        // Mock convertToAssets with the exact calldata (selector + shares amount)
        vm.mockCall(vault, abi.encodeWithSelector(IERC4626.convertToAssets.selector, jtOwnedShares), abi.encode(newAssetsValue));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VAULT SHARE PRICE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that ST vault share price yield increases NAV
    function testFuzz_stVaultSharePrice_yield_updatesNAV(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldPercentage) external virtual {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 2);
        _stPercentage = bound(_stPercentage, 10, 50);
        _yieldPercentage = bound(_yieldPercentage, 1, 50); // 1-50% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT navBefore = ST.totalAssets().nav;

        // Simulate ST vault share price yield
        simulateSTYield(_yieldPercentage * 1e16); // Convert to WAD

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = ST.totalAssets().nav;
        assertGt(navAfter, navBefore, "ST NAV should increase after vault share price yield");
    }

    /// @notice Tests that JT vault share price yield increases NAV
    function testFuzz_jtVaultSharePrice_yield_updatesNAV(uint256 _jtAmount, uint256 _yieldPercentage) external virtual {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 2);
        _yieldPercentage = bound(_yieldPercentage, 1, 50); // 1-50% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate JT vault share price yield
        simulateJTYield(_yieldPercentage * 1e16); // Convert to WAD

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "JT NAV should increase after vault share price yield");
    }

    /// @notice Tests that vault share price loss decreases NAV
    function testFuzz_vaultSharePrice_loss_updatesNAV(uint256 _jtAmount, uint256 _lossPercentage) external virtual {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 2);
        _lossPercentage = bound(_lossPercentage, 1, 30); // 1-30% loss

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate vault share price loss
        simulateJTLoss(_lossPercentage * 1e16); // Convert to WAD

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after vault share price loss");
    }

    /// @notice Tests NAV conservation after vault share price changes
    function testFuzz_vaultSharePrice_NAVConservation(uint256 _jtAmount, uint256 _yieldPercentage) external virtual {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 2);
        _yieldPercentage = bound(_yieldPercentage, 1, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Simulate vault share price yield
        simulateJTYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        _assertNAVConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the ERC4626 kernel and market
    function _deployKernelAndMarket() internal virtual override returns (DeployScript.DeploymentResult memory) {
        ProtocolConfig memory cfg = getProtocolConfig();

        bytes32 marketId = keccak256(abi.encodePacked(cfg.name, "-", cfg.name, "-", vm.getBlockTimestamp()));

        DeployScript.ERC4626STERC4626JTInKindAssetsKernelParams memory kernelParams =
            DeployScript.ERC4626STERC4626JTInKindAssetsKernelParams({ stVault: _getSTVault(), jtVault: _getJTVault() });

        DeployScript.AdaptiveCurveYDMParams memory ydmParams = DeployScript.AdaptiveCurveYDMParams({
            jtYieldShareAtTargetUtilWAD: 0.3e18, // 30% at target utilization
            jtYieldShareAtFullUtilWAD: 1e18 // 100% at 100% utilization
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
            stNAVDustTolerance: toNAVUnits(10 ** (18 - cfg.stDecimals)),
            jtNAVDustTolerance: toNAVUnits(10 ** (18 - cfg.jtDecimals)),
            kernelType: DeployScript.KernelType.ERC4626_ST_ERC4626_JT_InKindAssets,
            kernelSpecificParams: abi.encode(kernelParams),
            protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS,
            jtRedemptionDelayInSeconds: _getJTRedemptionDelay(),
            stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
            jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            coverageWAD: COVERAGE_WAD,
            betaWAD: 1e18, // Beta = 1 for identical vaults
            lltvWAD: LLTV,
            fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
            ydmType: DeployScript.YDMType.AdaptiveCurve,
            ydmSpecificParams: abi.encode(ydmParams),
            roleAssignments: roleAssignments
        });

        return DEPLOY_SCRIPT.deploy(params, DEPLOYER.privateKey);
    }
}
