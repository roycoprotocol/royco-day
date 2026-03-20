// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Vm } from "../../../lib/forge-std/src/Vm.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { DeploySyncerScript } from "../../../script/independent/DeploySyncer.s.sol";
import { RoycoBase } from "../../../src/base/RoycoBase.sol";
import { RolesConfiguration } from "../../../src/factory/RolesConfiguration.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoFactory } from "../../../src/interfaces/IRoycoFactory.sol";
import { RoycoMarketSyncer } from "../../../src/periphery/RoycoMarketSyncer.sol";

/// @dev Mock kernel contract for testing
contract MockKernel {
    address public immutable SENIOR_TRANCHE;
    bool public shouldRevert;
    bool public shouldRevertWithCustomError;
    uint256 public syncCallCount;

    error CustomSyncError(uint256 code, string reason);

    constructor(address _seniorTranche) {
        SENIOR_TRANCHE = _seniorTranche;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setShouldRevertWithCustomError(bool _shouldRevert) external {
        shouldRevertWithCustomError = _shouldRevert;
    }

    function syncTrancheAccounting() external {
        if (shouldRevertWithCustomError) revert CustomSyncError(42, "custom error");
        if (shouldRevert) revert("MockKernel: sync failed");
        syncCallCount++;
    }
}

/// @dev Mock tranche contract for testing
contract MockTranche {
    address public immutable KERNEL;

    constructor(address _kernel) {
        KERNEL = _kernel;
    }
}

/**
 * @title RoycoMarketSyncerTest
 * @notice Comprehensive test suite for the RoycoMarketSyncer contract
 * @dev Uses the DeploySyncer script to deploy the syncer and mock kernels for testing
 */
contract RoycoMarketSyncerTest is Test, RolesConfiguration {
    // ═══════════════════════════════════════════════════════════════════════════
    // TEST STATE
    // ═══════════════════════════════════════════════════════════════════════════

    DeploySyncerScript internal deployScript;
    RoycoMarketSyncer internal syncer;
    address internal mockFactory;

    // Mock kernels and tranches
    MockKernel internal mockKernel1;
    MockKernel internal mockKernel2;
    MockKernel internal mockKernel3;
    MockTranche internal mockTranche1;
    MockTranche internal mockTranche2;
    MockTranche internal mockTranche3;

    // Test wallets
    Vm.Wallet internal DEPLOYER;
    address internal DEPLOYER_ADDRESS;

    Vm.Wallet internal SYNC_OPERATOR;
    address internal SYNC_OPERATOR_ADDRESS;

    Vm.Wallet internal KERNEL_ADMIN;
    address internal KERNEL_ADMIN_ADDRESS;

    Vm.Wallet internal PAUSER;
    address internal PAUSER_ADDRESS;

    Vm.Wallet internal UNAUTHORIZED_USER;
    address internal UNAUTHORIZED_USER_ADDRESS;

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public {
        // Setup wallets
        _setupWallets();

        // Deploy CREATE2 factory (deterministic deployer)
        _deployCreate2Factory();

        // Create mock factory address
        mockFactory = makeAddr("MockFactory");

        // Deploy mock kernels and tranches
        _deployMockKernelsAndTranches();

        // Deploy syncer using the deployment script
        deployScript = new DeploySyncerScript();
        address[] memory emptyKernels = new address[](0);
        address syncerAddr = deployScript.deploySyncer(mockFactory, emptyKernels, DEPLOYER.privateKey);
        syncer = RoycoMarketSyncer(syncerAddr);

        // Label contracts for debugging
        vm.label(address(syncer), "Syncer");
        vm.label(mockFactory, "MockFactory");
        vm.label(address(mockKernel1), "MockKernel1");
        vm.label(address(mockKernel2), "MockKernel2");
        vm.label(address(mockKernel3), "MockKernel3");

        // Configure roles for the syncer
        _configureRoles();
    }

    function _setupWallets() internal {
        DEPLOYER = vm.createWallet("DEPLOYER");
        DEPLOYER_ADDRESS = DEPLOYER.addr;
        vm.label(DEPLOYER_ADDRESS, "DEPLOYER");
        vm.deal(DEPLOYER_ADDRESS, 100 ether);

        SYNC_OPERATOR = vm.createWallet("SYNC_OPERATOR");
        SYNC_OPERATOR_ADDRESS = SYNC_OPERATOR.addr;
        vm.label(SYNC_OPERATOR_ADDRESS, "SYNC_OPERATOR");
        vm.deal(SYNC_OPERATOR_ADDRESS, 100 ether);

        KERNEL_ADMIN = vm.createWallet("KERNEL_ADMIN");
        KERNEL_ADMIN_ADDRESS = KERNEL_ADMIN.addr;
        vm.label(KERNEL_ADMIN_ADDRESS, "KERNEL_ADMIN");
        vm.deal(KERNEL_ADMIN_ADDRESS, 100 ether);

        PAUSER = vm.createWallet("PAUSER");
        PAUSER_ADDRESS = PAUSER.addr;
        vm.label(PAUSER_ADDRESS, "PAUSER");
        vm.deal(PAUSER_ADDRESS, 100 ether);

        UNAUTHORIZED_USER = vm.createWallet("UNAUTHORIZED_USER");
        UNAUTHORIZED_USER_ADDRESS = UNAUTHORIZED_USER.addr;
        vm.label(UNAUTHORIZED_USER_ADDRESS, "UNAUTHORIZED_USER");
        vm.deal(UNAUTHORIZED_USER_ADDRESS, 100 ether);
    }

    function _deployCreate2Factory() internal {
        // Deploy the deterministic CREATE2 factory
        // This is the standard CREATE2 deployer bytecode
        bytes memory create2FactoryBytecode =
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
        vm.etch(CREATE2_FACTORY, create2FactoryBytecode);
    }

    function _deployMockKernelsAndTranches() internal {
        // Create mock tranche addresses
        address tranche1Addr = makeAddr("Tranche1");
        address tranche2Addr = makeAddr("Tranche2");
        address tranche3Addr = makeAddr("Tranche3");

        // Deploy kernels pointing to tranche addresses
        mockKernel1 = new MockKernel(tranche1Addr);
        mockKernel2 = new MockKernel(tranche2Addr);
        mockKernel3 = new MockKernel(tranche3Addr);

        // Deploy tranches pointing back to kernels
        mockTranche1 = new MockTranche(address(mockKernel1));
        mockTranche2 = new MockTranche(address(mockKernel2));
        mockTranche3 = new MockTranche(address(mockKernel3));

        // Mock the tranche addresses to have the MockTranche code
        vm.etch(tranche1Addr, address(mockTranche1).code);
        vm.etch(tranche2Addr, address(mockTranche2).code);
        vm.etch(tranche3Addr, address(mockTranche3).code);

        // Store the KERNEL slot in the tranche contracts (slot 0 for immutable KERNEL)
        vm.store(tranche1Addr, bytes32(0), bytes32(uint256(uint160(address(mockKernel1)))));
        vm.store(tranche2Addr, bytes32(0), bytes32(uint256(uint160(address(mockKernel2)))));
        vm.store(tranche3Addr, bytes32(0), bytes32(uint256(uint160(address(mockKernel3)))));
    }

    function _configureRoles() internal {
        // Mock the factory's canCall function to allow our test wallets to call syncer functions

        // Allow SYNC_OPERATOR to call executeBatchAccountingSync and executeBatchAccountingSyncFor (immediate, no delay)
        vm.mockCall(
            mockFactory,
            abi.encodeWithSelector(
                IAccessManager.canCall.selector, SYNC_OPERATOR_ADDRESS, address(syncer), RoycoMarketSyncer.executeBatchAccountingSync.selector
            ),
            abi.encode(true, uint32(0))
        );
        vm.mockCall(
            mockFactory,
            abi.encodeWithSelector(
                IAccessManager.canCall.selector, SYNC_OPERATOR_ADDRESS, address(syncer), RoycoMarketSyncer.executeBatchAccountingSyncFor.selector
            ),
            abi.encode(true, uint32(0))
        );

        // Allow KERNEL_ADMIN to call addMarketKernels (immediate for testing)
        vm.mockCall(
            mockFactory,
            abi.encodeWithSelector(IAccessManager.canCall.selector, KERNEL_ADMIN_ADDRESS, address(syncer), RoycoMarketSyncer.addMarketKernels.selector),
            abi.encode(true, uint32(0))
        );

        // Allow KERNEL_ADMIN to call removeMarketKernels (immediate for testing)
        vm.mockCall(
            mockFactory,
            abi.encodeWithSelector(IAccessManager.canCall.selector, KERNEL_ADMIN_ADDRESS, address(syncer), RoycoMarketSyncer.removeMarketKernels.selector),
            abi.encode(true, uint32(0))
        );

        // Allow PAUSER to call pause/unpause (immediate)
        vm.mockCall(
            mockFactory,
            abi.encodeWithSelector(IAccessManager.canCall.selector, PAUSER_ADDRESS, address(syncer), IRoycoAuth.pause.selector),
            abi.encode(true, uint32(0))
        );

        vm.mockCall(
            mockFactory,
            abi.encodeWithSelector(IAccessManager.canCall.selector, PAUSER_ADDRESS, address(syncer), IRoycoAuth.unpause.selector),
            abi.encode(true, uint32(0))
        );

        // Mock factory's seniorTrancheToJuniorTranche to return valid junior tranche for valid kernels
        vm.mockCall(
            mockFactory,
            abi.encodeWithSelector(IRoycoFactory.seniorTrancheToJuniorTranche.selector, mockKernel1.SENIOR_TRANCHE()),
            abi.encode(makeAddr("JuniorTranche1"))
        );

        vm.mockCall(
            mockFactory,
            abi.encodeWithSelector(IRoycoFactory.seniorTrancheToJuniorTranche.selector, mockKernel2.SENIOR_TRANCHE()),
            abi.encode(makeAddr("JuniorTranche2"))
        );

        vm.mockCall(
            mockFactory,
            abi.encodeWithSelector(IRoycoFactory.seniorTrancheToJuniorTranche.selector, mockKernel3.SENIOR_TRANCHE()),
            abi.encode(makeAddr("JuniorTranche3"))
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Helper to add kernels with proper permissions
    function _addKernels(address[] memory kernels) internal {
        vm.prank(KERNEL_ADMIN_ADDRESS);
        syncer.addMarketKernels(kernels);
    }

    /// @notice Helper to remove kernels with proper permissions
    function _removeKernels(address[] memory kernels) internal {
        vm.prank(KERNEL_ADMIN_ADDRESS);
        syncer.removeMarketKernels(kernels);
    }

    /// @notice Helper to get all mock kernels as array
    function _getAllKernels() internal view returns (address[] memory) {
        address[] memory kernels = new address[](3);
        kernels[0] = address(mockKernel1);
        kernels[1] = address(mockKernel2);
        kernels[2] = address(mockKernel3);
        return kernels;
    }

    /// @notice Helper to get single kernel as array
    function _singleKernelArray(address kernel) internal pure returns (address[] memory) {
        address[] memory kernels = new address[](1);
        kernels[0] = kernel;
        return kernels;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 1: INITIALIZATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that syncer initializes correctly with empty kernels
    function test_initialize_withEmptyKernels() external view {
        address[] memory kernels = syncer.getMarketKernels();
        assertEq(kernels.length, 0, "Should initialize with no kernels");
    }

    /// @notice Test that syncer initializes with correct authority
    function test_initialize_setsCorrectAuthority() external view {
        assertEq(syncer.authority(), mockFactory, "Authority should be factory");
    }

    /// @notice Test that syncer cannot be reinitialized
    function test_initialize_cannotReinitialize() external {
        address[] memory kernels = new address[](0);
        vm.expectRevert();
        syncer.initialize(mockFactory, kernels);
    }

    /// @notice Test initialization with kernels using deployment script
    function test_initialize_withKernels() external {
        // Deploy a new syncer with kernels using the deployment script
        address[] memory initialKernels = _getAllKernels();
        address newSyncerAddr = deployScript.deploySyncer(mockFactory, initialKernels, DEPLOYER.privateKey);
        RoycoMarketSyncer newSyncer = RoycoMarketSyncer(newSyncerAddr);

        address[] memory kernels = newSyncer.getMarketKernels();
        assertEq(kernels.length, 3, "Should initialize with 3 kernels");
    }

    /// @notice Test deployment script returns deterministic address
    function test_deploy_deterministicAddress() external {
        // Deploy syncer twice - should get same address due to CREATE2
        address[] memory emptyKernels = new address[](0);

        // First deployment already happened in setUp, get the address
        address firstDeployAddr = address(syncer);

        // Deploy again - should return same address (already deployed)
        address secondDeployAddr = deployScript.deploySyncer(mockFactory, emptyKernels, DEPLOYER.privateKey);

        assertEq(firstDeployAddr, secondDeployAddr, "CREATE2 should give deterministic address");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 2: KERNEL VALIDATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that valid mock kernels pass validation
    function test_validation_validKernelsPasses() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        address[] memory registeredKernels = syncer.getMarketKernels();
        assertEq(registeredKernels.length, 1, "Should have 1 kernel");
        assertEq(registeredKernels[0], address(mockKernel1), "Should be mockKernel1");
    }

    /// @notice Test that null address fails validation
    function test_validation_nullAddressReverts() external {
        address[] memory kernels = new address[](1);
        kernels[0] = address(0);

        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert();
        syncer.addMarketKernels(kernels);
    }

    /// @notice Test that random address fails validation (no factory mapping)
    function test_validation_invalidKernelReverts_noJuniorTranche() external {
        // Create a mock that has SENIOR_TRANCHE but factory returns address(0) for it
        MockKernel fakeKernel = new MockKernel(makeAddr("FakeTranche"));

        // Mock factory to return address(0) for this tranche (indicating not from factory)
        vm.mockCall(
            mockFactory, abi.encodeWithSelector(IRoycoFactory.seniorTrancheToJuniorTranche.selector, fakeKernel.SENIOR_TRANCHE()), abi.encode(address(0))
        );

        address[] memory kernels = _singleKernelArray(address(fakeKernel));

        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(RoycoMarketSyncer.INVALID_KERNEL.selector, address(fakeKernel)));
        syncer.addMarketKernels(kernels);
    }

    /// @notice Test that kernel fails validation when tranche.KERNEL() doesn't match
    function test_validation_invalidKernelReverts_kernelMismatch() external {
        // Create a fake kernel with a tranche that points to a DIFFERENT kernel
        address fakeTranche = makeAddr("FakeTranche2");
        MockKernel fakeKernel = new MockKernel(fakeTranche);

        // Deploy a tranche that points to a DIFFERENT kernel (not fakeKernel)
        address differentKernel = makeAddr("DifferentKernel");
        MockTranche mismatchedTranche = new MockTranche(differentKernel);
        vm.etch(fakeTranche, address(mismatchedTranche).code);
        vm.store(fakeTranche, bytes32(0), bytes32(uint256(uint160(differentKernel))));

        // Mock factory to return a valid junior tranche (non-zero)
        vm.mockCall(
            mockFactory, abi.encodeWithSelector(IRoycoFactory.seniorTrancheToJuniorTranche.selector, fakeTranche), abi.encode(makeAddr("SomeJuniorTranche"))
        );

        address[] memory kernels = _singleKernelArray(address(fakeKernel));

        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(RoycoMarketSyncer.INVALID_KERNEL.selector, address(fakeKernel)));
        syncer.addMarketKernels(kernels);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 3: ADD KERNELS TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test adding a single kernel
    function test_addKernels_single() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        address[] memory registeredKernels = syncer.getMarketKernels();
        assertEq(registeredKernels.length, 1, "Should have 1 kernel");
    }

    /// @notice Test adding multiple kernels at once
    function test_addKernels_multiple() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        address[] memory registeredKernels = syncer.getMarketKernels();
        assertEq(registeredKernels.length, 3, "Should have 3 kernels");
    }

    /// @notice Test adding kernels emits events
    function test_addKernels_emitsEvents() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        vm.expectEmit(true, false, false, true, address(syncer));
        emit RoycoMarketSyncer.MarketKernelAdded(address(mockKernel1));

        vm.prank(KERNEL_ADMIN_ADDRESS);
        syncer.addMarketKernels(kernels);
    }

    /// @notice Test adding duplicate kernel reverts
    function test_addKernels_duplicateReverts() external {
        // Add first time
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Try to add again - should revert
        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(RoycoMarketSyncer.KERNEL_ALREADY_REGISTERED.selector, address(mockKernel1)));
        syncer.addMarketKernels(kernels);
    }

    /// @notice Test adding empty array succeeds (no-op)
    function test_addKernels_emptyArray() external {
        address[] memory kernels = new address[](0);
        _addKernels(kernels);
        assertEq(syncer.getMarketKernels().length, 0, "Should still have 0 kernels");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 4: REMOVE KERNELS TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test removing a single kernel
    function test_removeKernels_single() external {
        // First add kernels
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);
        assertEq(syncer.getMarketKernels().length, 3, "Should have 3 kernels");

        // Remove one
        address[] memory toRemove = _singleKernelArray(address(mockKernel1));
        _removeKernels(toRemove);

        address[] memory remaining = syncer.getMarketKernels();
        assertEq(remaining.length, 2, "Should have 2 kernels");
    }

    /// @notice Test removing multiple kernels
    function test_removeKernels_multiple() external {
        // First add kernels
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        // Remove all
        _removeKernels(kernels);

        assertEq(syncer.getMarketKernels().length, 0, "Should have 0 kernels");
    }

    /// @notice Test removing emits events
    function test_removeKernels_emitsEvents() external {
        // First add kernel
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        vm.expectEmit(true, false, false, true, address(syncer));
        emit RoycoMarketSyncer.MarketKernelRemoved(address(mockKernel1));

        vm.prank(KERNEL_ADMIN_ADDRESS);
        syncer.removeMarketKernels(kernels);
    }

    /// @notice Test removing non-existent kernel reverts
    function test_removeKernels_nonExistentReverts() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(RoycoMarketSyncer.KERNEL_IS_NOT_REGISTERED.selector, address(mockKernel1)));
        syncer.removeMarketKernels(kernels);
    }

    /// @notice Test removing empty array succeeds (no-op)
    function test_removeKernels_emptyArray() external {
        address[] memory kernels = new address[](0);
        _removeKernels(kernels);
        // Should succeed without reverting
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 5: EXECUTE BATCH ACCOUNTING SYNC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test batch sync with single kernel succeeds
    function test_executeBatchSync_singleKernel() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Execute sync
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify sync was called
        assertEq(mockKernel1.syncCallCount(), 1, "Sync should have been called once");
    }

    /// @notice Test batch sync with multiple kernels succeeds
    function test_executeBatchSync_multipleKernels() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        // Execute sync
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify all syncs were called
        assertEq(mockKernel1.syncCallCount(), 1, "Kernel1 sync should have been called");
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 sync should have been called");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 sync should have been called");
    }

    /// @notice Test batch sync with zero kernels succeeds (no-op)
    function test_executeBatchSync_zeroKernels() external {
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);
        // Should succeed without reverting
    }

    /// @notice Test batch sync tolerates individual kernel failures when flag is true
    function test_executeBatchSync_toleratesFailures() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        // Set first kernel to fail
        mockKernel1.setShouldRevert(true);

        // Should still succeed with tolerance
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify other kernels were still synced
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 sync should have been called");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 sync should have been called");
    }

    /// @notice Test batch sync emits failure event when kernel fails
    function test_executeBatchSync_emitsFailureEvent() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Set kernel to fail
        mockKernel1.setShouldRevert(true);

        vm.expectEmit(true, false, false, false, address(syncer));
        emit RoycoMarketSyncer.AccountingSyncFailed(address(mockKernel1), "");

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);
    }

    /// @notice Test batch sync reverts on failure when tolerance is false
    function test_executeBatchSync_revertsOnFailureWhenNotTolerant() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Set kernel to fail
        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        // Verify the exact error is propagated from the kernel
        vm.expectRevert("MockKernel: sync failed");
        syncer.executeBatchAccountingSync(false);
    }

    /// @notice Test batch sync propagates the exact error from failing kernel
    function test_executeBatchSync_propagatesExactError() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Set kernel to fail
        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        // The error "MockKernel: sync failed" should be propagated exactly
        vm.expectRevert("MockKernel: sync failed");
        syncer.executeBatchAccountingSync(false);
    }

    /// @notice Test batch sync propagates custom errors correctly
    function test_executeBatchSync_propagatesCustomError() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Set kernel to fail with custom error
        mockKernel1.setShouldRevertWithCustomError(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        // The custom error should be propagated exactly
        vm.expectRevert(abi.encodeWithSelector(MockKernel.CustomSyncError.selector, 42, "custom error"));
        syncer.executeBatchAccountingSync(false);
    }

    /// @notice Test that error bytes are propagated exactly (byte-by-byte verification)
    function test_executeBatchSync_errorBytesMatchExactly() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Set kernel to fail
        mockKernel1.setShouldRevert(true);

        // Get expected error bytes by calling kernel directly
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        // Now call through syncer and capture the propagated error
        bytes memory actualErrorBytes;
        vm.prank(SYNC_OPERATOR_ADDRESS);
        try syncer.executeBatchAccountingSync(false) {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            actualErrorBytes = errorBytes;
        }

        // Verify the error bytes match exactly
        assertEq(actualErrorBytes, expectedErrorBytes, "Error bytes should be propagated exactly");
    }

    /// @notice Test batch sync success path does not emit failure event
    function test_executeBatchSync_successDoesNotEmitFailureEvent() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Record logs to verify no AccountingSyncFailed event is emitted
        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Get all emitted logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify no AccountingSyncFailed event was emitted
        bytes32 failureEventSig = keccak256("AccountingSyncFailed(address,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != failureEventSig, "Should not emit AccountingSyncFailed on success");
        }

        // Verify sync was actually called
        assertEq(mockKernel1.syncCallCount(), 1, "Sync should have been called");
    }

    /// @notice Test batch sync continues after failure when tolerant
    function test_executeBatchSync_continuesAfterFailure() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        // Set first kernel to fail
        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify that kernel2 and kernel3 were still called
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 should have been synced");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 should have been synced");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 5B: EXECUTE BATCH ACCOUNTING SYNC FOR (SPECIFIC KERNELS) TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test batch sync for specific kernels with single kernel succeeds
    function test_executeBatchSyncFor_singleKernel() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        assertEq(mockKernel1.syncCallCount(), 1, "Sync should have been called once");
    }

    /// @notice Test batch sync for specific kernels with multiple kernels succeeds
    function test_executeBatchSyncFor_multipleKernels() external {
        address[] memory kernels = _getAllKernels();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        assertEq(mockKernel1.syncCallCount(), 1, "Kernel1 sync should have been called");
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 sync should have been called");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 sync should have been called");
    }

    /// @notice Test batch sync for specific kernels with zero kernels succeeds (no-op)
    function test_executeBatchSyncFor_zeroKernels() external {
        address[] memory kernels = new address[](0);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);
        // Should succeed without reverting
    }

    /// @notice Test batch sync for specific kernels tolerates individual kernel failures when flag is true
    function test_executeBatchSyncFor_toleratesFailures() external {
        address[] memory kernels = _getAllKernels();

        // Set first kernel to fail
        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        // Verify other kernels were still synced
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 sync should have been called");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 sync should have been called");
    }

    /// @notice Test batch sync for specific kernels emits failure event when kernel fails
    function test_executeBatchSyncFor_emitsFailureEvent() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        mockKernel1.setShouldRevert(true);

        vm.expectEmit(true, false, false, false, address(syncer));
        emit RoycoMarketSyncer.AccountingSyncFailed(address(mockKernel1), "");

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);
    }

    /// @notice Test batch sync for specific kernels reverts on failure when tolerance is false
    function test_executeBatchSyncFor_revertsOnFailureWhenNotTolerant() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert("MockKernel: sync failed");
        syncer.executeBatchAccountingSyncFor(kernels, false);
    }

    /// @notice Test batch sync for specific kernels propagates the exact error from failing kernel
    function test_executeBatchSyncFor_propagatesExactError() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert("MockKernel: sync failed");
        syncer.executeBatchAccountingSyncFor(kernels, false);
    }

    /// @notice Test batch sync for specific kernels propagates custom errors correctly
    function test_executeBatchSyncFor_propagatesCustomError() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        mockKernel1.setShouldRevertWithCustomError(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(MockKernel.CustomSyncError.selector, 42, "custom error"));
        syncer.executeBatchAccountingSyncFor(kernels, false);
    }

    /// @notice Test that error bytes are propagated exactly for specific kernels (byte-by-byte verification)
    function test_executeBatchSyncFor_errorBytesMatchExactly() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        mockKernel1.setShouldRevert(true);

        // Get expected error bytes by calling kernel directly
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        // Now call through syncer and capture the propagated error
        bytes memory actualErrorBytes;
        vm.prank(SYNC_OPERATOR_ADDRESS);
        try syncer.executeBatchAccountingSyncFor(kernels, false) {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            actualErrorBytes = errorBytes;
        }

        assertEq(actualErrorBytes, expectedErrorBytes, "Error bytes should be propagated exactly");
    }

    /// @notice Test batch sync for specific kernels success path does not emit failure event
    function test_executeBatchSyncFor_successDoesNotEmitFailureEvent() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 failureEventSig = keccak256("AccountingSyncFailed(address,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != failureEventSig, "Should not emit AccountingSyncFailed on success");
        }

        assertEq(mockKernel1.syncCallCount(), 1, "Sync should have been called");
    }

    /// @notice Test batch sync for specific kernels continues after failure when tolerant
    function test_executeBatchSyncFor_continuesAfterFailure() external {
        address[] memory kernels = _getAllKernels();

        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 should have been synced");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 should have been synced");
    }

    /// @notice Test batch sync for specific kernels works with unregistered kernels
    function test_executeBatchSyncFor_worksWithUnregisteredKernels() external {
        // Don't register kernels, just sync them directly
        address[] memory kernels = _getAllKernels();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        // Verify all kernels were synced even though they weren't registered
        assertEq(mockKernel1.syncCallCount(), 1, "Kernel1 sync should have been called");
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 sync should have been called");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 sync should have been called");

        // Verify they are not in the registered list
        address[] memory registeredKernels = syncer.getMarketKernels();
        assertEq(registeredKernels.length, 0, "No kernels should be registered");
    }

    /// @notice Test batch sync for specific kernels can sync same kernel multiple times
    function test_executeBatchSyncFor_canSyncSameKernelMultipleTimes() external {
        address[] memory kernels = new address[](3);
        kernels[0] = address(mockKernel1);
        kernels[1] = address(mockKernel1);
        kernels[2] = address(mockKernel1);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        assertEq(mockKernel1.syncCallCount(), 3, "Kernel1 should have been synced 3 times");
    }

    /// @notice Test batch sync for specific kernels with middle kernel failing
    function test_executeBatchSyncFor_middleKernelFails() external {
        address[] memory kernels = _getAllKernels();

        // Set middle kernel to fail
        mockKernel2.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        // Verify kernel1 and kernel3 were synced, kernel2 was attempted
        assertEq(mockKernel1.syncCallCount(), 1, "Kernel1 should have been synced");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 should have been synced");
    }

    /// @notice Test batch sync for specific kernels stops at first failure when not tolerant
    function test_executeBatchSyncFor_stopsAtFirstFailureWhenNotTolerant() external {
        address[] memory kernels = _getAllKernels();

        // Set first kernel to fail
        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert("MockKernel: sync failed");
        syncer.executeBatchAccountingSyncFor(kernels, false);

        // Verify subsequent kernels were NOT called
        assertEq(mockKernel2.syncCallCount(), 0, "Kernel2 should NOT have been synced");
        assertEq(mockKernel3.syncCallCount(), 0, "Kernel3 should NOT have been synced");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 6: ACCESS CONTROL TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test unauthorized user cannot execute batch sync
    function test_accessControl_unauthorizedCannotSync() external {
        vm.prank(UNAUTHORIZED_USER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, UNAUTHORIZED_USER_ADDRESS));
        syncer.executeBatchAccountingSync(true);
    }

    /// @notice Test unauthorized user cannot execute batch sync for specific kernels
    function test_accessControl_unauthorizedCannotSyncFor() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        vm.prank(UNAUTHORIZED_USER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, UNAUTHORIZED_USER_ADDRESS));
        syncer.executeBatchAccountingSyncFor(kernels, true);
    }

    /// @notice Test unauthorized user cannot add kernels
    function test_accessControl_unauthorizedCannotAddKernels() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        vm.prank(UNAUTHORIZED_USER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, UNAUTHORIZED_USER_ADDRESS));
        syncer.addMarketKernels(kernels);
    }

    /// @notice Test unauthorized user cannot remove kernels
    function test_accessControl_unauthorizedCannotRemoveKernels() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        vm.prank(UNAUTHORIZED_USER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, UNAUTHORIZED_USER_ADDRESS));
        syncer.removeMarketKernels(kernels);
    }

    /// @notice Test unauthorized user cannot pause
    function test_accessControl_unauthorizedCannotPause() external {
        vm.prank(UNAUTHORIZED_USER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, UNAUTHORIZED_USER_ADDRESS));
        syncer.pause();
    }

    /// @notice Test sync operator cannot add kernels
    function test_accessControl_syncOperatorCannotAddKernels() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, SYNC_OPERATOR_ADDRESS));
        syncer.addMarketKernels(kernels);
    }

    /// @notice Test kernel admin cannot sync
    function test_accessControl_kernelAdminCannotSync() external {
        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, KERNEL_ADMIN_ADDRESS));
        syncer.executeBatchAccountingSync(true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 7: PAUSABILITY TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test syncer can be paused
    function test_pause_succeeds() external {
        assertFalse(PausableUpgradeable(address(syncer)).paused(), "Should not be paused initially");

        vm.prank(PAUSER_ADDRESS);
        syncer.pause();

        assertTrue(PausableUpgradeable(address(syncer)).paused(), "Should be paused");
    }

    /// @notice Test syncer can be unpaused
    function test_unpause_succeeds() external {
        vm.prank(PAUSER_ADDRESS);
        syncer.pause();
        assertTrue(PausableUpgradeable(address(syncer)).paused(), "Should be paused");

        vm.prank(PAUSER_ADDRESS);
        syncer.unpause();
        assertFalse(PausableUpgradeable(address(syncer)).paused(), "Should be unpaused");
    }

    /// @notice Test batch sync fails when paused
    function test_pause_blocksBatchSync() external {
        vm.prank(PAUSER_ADDRESS);
        syncer.pause();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        syncer.executeBatchAccountingSync(true);
    }

    /// @notice Test pause blocks executeBatchAccountingSyncFor
    function test_pause_blocksBatchSyncFor() external {
        vm.prank(PAUSER_ADDRESS);
        syncer.pause();

        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        syncer.executeBatchAccountingSyncFor(kernels, true);
    }

    /// @notice Test add kernels fails when paused
    function test_pause_blocksAddKernels() external {
        vm.prank(PAUSER_ADDRESS);
        syncer.pause();

        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        syncer.addMarketKernels(kernels);
    }

    /// @notice Test remove kernels fails when paused
    function test_pause_blocksRemoveKernels() external {
        // First add kernels while unpaused
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Now pause
        vm.prank(PAUSER_ADDRESS);
        syncer.pause();

        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        syncer.removeMarketKernels(kernels);
    }

    /// @notice Test operations work after unpause
    function test_pause_operationsWorkAfterUnpause() external {
        // Pause
        vm.prank(PAUSER_ADDRESS);
        syncer.pause();

        // Unpause
        vm.prank(PAUSER_ADDRESS);
        syncer.unpause();

        // Add kernels should work
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        assertEq(syncer.getMarketKernels().length, 1, "Should have 1 kernel");

        // Sync should work
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 8: VIEW FUNCTIONS TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test getMarketKernels returns correct kernels
    function test_getMarketKernels_returnsCorrectKernels() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        address[] memory result = syncer.getMarketKernels();
        assertEq(result.length, 3, "Should have 3 kernels");

        // Note: Order may not be preserved due to EnumerableSet implementation
        bool foundKernel1 = false;
        bool foundKernel2 = false;
        bool foundKernel3 = false;
        for (uint256 i = 0; i < result.length; i++) {
            if (result[i] == address(mockKernel1)) foundKernel1 = true;
            if (result[i] == address(mockKernel2)) foundKernel2 = true;
            if (result[i] == address(mockKernel3)) foundKernel3 = true;
        }
        assertTrue(foundKernel1, "Should contain kernel1");
        assertTrue(foundKernel2, "Should contain kernel2");
        assertTrue(foundKernel3, "Should contain kernel3");
    }

    /// @notice Test getMarketKernels returns empty array when no kernels
    function test_getMarketKernels_returnsEmptyWhenNone() external view {
        address[] memory result = syncer.getMarketKernels();
        assertEq(result.length, 0, "Should have 0 kernels");
    }

    /// @notice Test isMarketKernelRegistered returns true for registered kernel
    function test_isMarketKernelRegistered_returnsTrueForRegistered() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        assertTrue(syncer.isMarketKernelRegistered(address(mockKernel1)), "Kernel1 should be registered");
    }

    /// @notice Test isMarketKernelRegistered returns false for unregistered kernel
    function test_isMarketKernelRegistered_returnsFalseForUnregistered() external view {
        assertFalse(syncer.isMarketKernelRegistered(address(mockKernel1)), "Kernel1 should not be registered");
    }

    /// @notice Test isMarketKernelRegistered returns false after kernel is removed
    function test_isMarketKernelRegistered_returnsFalseAfterRemoval() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        assertTrue(syncer.isMarketKernelRegistered(address(mockKernel1)), "Kernel1 should be registered");

        _removeKernels(kernels);

        assertFalse(syncer.isMarketKernelRegistered(address(mockKernel1)), "Kernel1 should not be registered after removal");
    }

    /// @notice Test isMarketKernelRegistered returns false for zero address
    function test_isMarketKernelRegistered_returnsFalseForZeroAddress() external view {
        assertFalse(syncer.isMarketKernelRegistered(address(0)), "Zero address should not be registered");
    }

    /// @notice Test isMarketKernelRegistered with multiple kernels registered
    function test_isMarketKernelRegistered_multipleKernels() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        assertTrue(syncer.isMarketKernelRegistered(address(mockKernel1)), "Kernel1 should be registered");
        assertTrue(syncer.isMarketKernelRegistered(address(mockKernel2)), "Kernel2 should be registered");
        assertTrue(syncer.isMarketKernelRegistered(address(mockKernel3)), "Kernel3 should be registered");

        // Random address should not be registered
        assertFalse(syncer.isMarketKernelRegistered(address(0x1234)), "Random address should not be registered");
    }

    /// @notice Test isMarketKernelRegistered correctly tracks partial removals
    function test_isMarketKernelRegistered_partialRemoval() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        // Remove only kernel2
        address[] memory toRemove = _singleKernelArray(address(mockKernel2));
        _removeKernels(toRemove);

        assertTrue(syncer.isMarketKernelRegistered(address(mockKernel1)), "Kernel1 should still be registered");
        assertFalse(syncer.isMarketKernelRegistered(address(mockKernel2)), "Kernel2 should not be registered");
        assertTrue(syncer.isMarketKernelRegistered(address(mockKernel3)), "Kernel3 should still be registered");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 9: UPGRADE TESTS (inherited from RoycoBase)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that authorized user can upgrade to valid implementation
    function test_upgrade_authorizedCanUpgrade() external {
        // Deploy new implementation
        RoycoMarketSyncer newImpl = new RoycoMarketSyncer();

        // Mock permission for upgrade
        vm.mockCall(
            mockFactory,
            abi.encodeWithSelector(IAccessManager.canCall.selector, DEPLOYER_ADDRESS, address(syncer), syncer.upgradeToAndCall.selector),
            abi.encode(true, uint32(0))
        );

        vm.prank(DEPLOYER_ADDRESS);
        syncer.upgradeToAndCall(address(newImpl), "");

        // Verify upgrade succeeded - implementation changed
        // The syncer should still work after upgrade
        assertEq(syncer.authority(), mockFactory, "Authority should remain after upgrade");
    }

    /// @notice Test that upgrade to EOA (no code) reverts
    function test_upgrade_invalidImplementationReverts() external {
        address eoaAddress = makeAddr("EOA");

        // Mock permission for upgrade
        vm.mockCall(
            mockFactory,
            abi.encodeWithSelector(IAccessManager.canCall.selector, DEPLOYER_ADDRESS, address(syncer), syncer.upgradeToAndCall.selector),
            abi.encode(true, uint32(0))
        );

        vm.prank(DEPLOYER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(RoycoBase.INVALID_IMPLEMENTATION.selector));
        syncer.upgradeToAndCall(eoaAddress, "");
    }

    /// @notice Test that unauthorized user cannot upgrade
    function test_upgrade_unauthorizedCannotUpgrade() external {
        RoycoMarketSyncer newImpl = new RoycoMarketSyncer();

        vm.prank(UNAUTHORIZED_USER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, UNAUTHORIZED_USER_ADDRESS));
        syncer.upgradeToAndCall(address(newImpl), "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 10: INTEGRATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test full workflow: add, sync, remove
    function test_integration_fullWorkflow() external {
        // Start with no kernels
        assertEq(syncer.getMarketKernels().length, 0, "Should start with 0 kernels");

        // Add all kernels
        address[] memory allKernels = _getAllKernels();
        _addKernels(allKernels);
        assertEq(syncer.getMarketKernels().length, 3, "Should have 3 kernels");

        // Execute sync
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify all syncs were called
        assertEq(mockKernel1.syncCallCount(), 1, "Kernel1 should have synced");
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 should have synced");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 should have synced");

        // Remove one kernel
        address[] memory toRemove = _singleKernelArray(address(mockKernel2));
        _removeKernels(toRemove);
        assertEq(syncer.getMarketKernels().length, 2, "Should have 2 kernels");

        // Sync again
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify only remaining kernels were synced again
        assertEq(mockKernel1.syncCallCount(), 2, "Kernel1 should have synced twice");
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 should still have 1 sync");
        assertEq(mockKernel3.syncCallCount(), 2, "Kernel3 should have synced twice");

        // Remove remaining
        address[] memory remaining = syncer.getMarketKernels();
        _removeKernels(remaining);
        assertEq(syncer.getMarketKernels().length, 0, "Should have 0 kernels");
    }

    /// @notice Test adding and removing same kernel multiple times
    function test_integration_addRemoveMultipleTimes() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        // Add
        _addKernels(kernels);
        assertEq(syncer.getMarketKernels().length, 1);

        // Remove
        _removeKernels(kernels);
        assertEq(syncer.getMarketKernels().length, 0);

        // Add again
        _addKernels(kernels);
        assertEq(syncer.getMarketKernels().length, 1);

        // Remove again
        _removeKernels(kernels);
        assertEq(syncer.getMarketKernels().length, 0);
    }

    /// @notice Test sync counts accumulate correctly
    function test_integration_syncCountsAccumulate() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Sync multiple times
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(SYNC_OPERATOR_ADDRESS);
            syncer.executeBatchAccountingSync(true);
        }

        assertEq(mockKernel1.syncCallCount(), 5, "Should have synced 5 times");
    }
}
