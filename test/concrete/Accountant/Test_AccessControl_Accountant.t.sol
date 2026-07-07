// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { Operation } from "../../../src/libraries/Types.sol";
import { toNAVUnits } from "../../../src/libraries/Units.sol";
import { MockAccountantKernel } from "../../mocks/MockAccountantKernel.sol";
import { MockRecordingYDM } from "../../mocks/MockRecordingYDM.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_AccessControl_Accountant
 * @notice The accountant's caller gates: the onlyRoycoKernel surface, the restricted setter surface for
 *         an unauthorized caller, and the sync-before-body ordering contract of the hard-sync setters
 *         (including the reverting-kernel recovery path reserved for the two YDM setters)
 */
contract Test_AccessControl_Accountant is AccountantTestBase {
    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(false, _defaultParams());
    }

    /// preOpSyncTrancheAccounting reverts for any non-kernel caller, including the admin
    function test_RevertIf_PreOpSyncFromNonKernel() public {
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.preOpSyncTrancheAccounting(toNAVUnits(uint256(1e18)), toNAVUnits(uint256(1e18)));
        vm.prank(stranger);
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.preOpSyncTrancheAccounting(toNAVUnits(uint256(1e18)), toNAVUnits(uint256(1e18)));
    }

    /// commitLiquidityTrancheRawNAV reverts for any non-kernel caller, including the admin
    function test_RevertIf_CommitFromNonKernel() public {
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.commitLiquidityTrancheRawNAV(toNAVUnits(uint256(1e18)));
        vm.prank(stranger);
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.commitLiquidityTrancheRawNAV(toNAVUnits(uint256(1e18)));
    }

    /// postOpSyncTrancheAccounting reverts for any non-kernel caller, including the admin
    function test_RevertIf_PostOpSyncFromNonKernel() public {
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, toNAVUnits(uint256(1e18)), ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
        vm.prank(stranger);
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, toNAVUnits(uint256(1e18)), ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
    }

    /// all 13 restricted setters (plus inherited pause/unpause) revert AccessManagedUnauthorized for a role-less caller
    function test_RevertIf_UnauthorizedCallerOnAllSetters() public {
        bytes[] memory calls = new bytes[](15);
        bytes[] memory hardSync = _hardSyncSetterCalls();
        for (uint256 i; i < 11; ++i) {
            calls[i] = hardSync[i];
        }
        calls[11] = abi.encodeCall(IRoycoDayAccountant.setJuniorTrancheYDM, (address(0xBEEF), bytes("")));
        calls[12] = abi.encodeCall(IRoycoDayAccountant.setLiquidityTrancheYDM, (address(0xBEEF), bytes("")));
        calls[13] = abi.encodeCall(IRoycoAuth.pause, ());
        calls[14] = abi.encodeCall(IRoycoAuth.unpause, ());
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
            (bool success,) = address(accountant).call(calls[i]);
            success;
        }
    }

    /// each of the 11 hard-sync setters calls the kernel sync BEFORE its body (snapshot taken at sync equals the pre-call state)
    function test_SetterSync_hardSyncSettersSyncBeforeBody() public {
        bytes[] memory calls = _hardSyncSetterCalls();
        for (uint256 i; i < calls.length; ++i) {
            uint256 countBefore = kernel.syncCallCount();
            bytes32 preHash = _stateHash();
            (bool success,) = address(accountant).call(calls[i]);
            assertTrue(success, "setter must succeed");
            assertEq(kernel.syncCallCount(), countBefore + 1, "kernel sync not attempted exactly once");
            assertEq(keccak256(abi.encode(kernel.stateAtLastSync())), preHash, "sync observed post-body state: body ran first");
            assertTrue(_stateHash() != preHash, "setter body must have mutated state");
        }
    }

    /// a REVERT-mode kernel bricks all 11 hard-sync setters
    function test_SetterSync_revertingKernelBricksHardSyncSetters() public {
        kernel.setSyncMode(MockAccountantKernel.SyncMode.REVERT);
        bytes[] memory calls = _hardSyncSetterCalls();
        bytes32 preHash = _stateHash();
        for (uint256 i; i < calls.length; ++i) {
            vm.expectRevert(MockAccountantKernel.KERNEL_SYNC_REVERTED.selector);
            (bool success,) = address(accountant).call(calls[i]);
            success;
        }
        assertEq(_stateHash(), preHash, "no setter body may have executed");
    }

    /// the two YDM setters tolerate a reverting kernel sync (the recovery path from a sync-bricking YDM)
    function test_SetterSync_ydmSettersTolerateRevertingKernel() public {
        kernel.setSyncMode(MockAccountantKernel.SyncMode.REVERT);
        MockRecordingYDM newJT = new MockRecordingYDM();
        accountant.setJuniorTrancheYDM(address(newJT), "");
        assertEq(accountant.getState().jtYDM, address(newJT), "jt ydm updated despite reverting kernel");
        MockRecordingYDM newLT = new MockRecordingYDM();
        accountant.setLiquidityTrancheYDM(address(newLT), "");
        assertEq(accountant.getState().ltYDM, address(newLT), "lt ydm updated despite reverting kernel");
    }

    /// the tolerated kernel sync is still attempted by both YDM setters (counted in NONE mode)
    function test_SetterSync_ydmSettersAttemptKernelSync() public {
        uint256 countBefore = kernel.syncCallCount();
        MockRecordingYDM newJT = new MockRecordingYDM();
        accountant.setJuniorTrancheYDM(address(newJT), "");
        assertEq(kernel.syncCallCount(), countBefore + 1, "jt setter attempted the sync");
        MockRecordingYDM newLT = new MockRecordingYDM();
        accountant.setLiquidityTrancheYDM(address(newLT), "");
        assertEq(kernel.syncCallCount(), countBefore + 2, "lt setter attempted the sync");
    }
}
