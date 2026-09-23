// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/accountant/IRoycoDayAccountant.sol";
import { IRoycoDayFixedRateAccountant } from "../../../src/interfaces/accountant/IRoycoDayFixedRateAccountant.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { Operation } from "../../../src/libraries/Types.sol";
import { toNAVUnits } from "../../../src/libraries/Units.sol";
import { MockFixedRateAccountantKernel } from "../../mocks/MockFixedRateAccountantKernel.sol";
import { MockRecordingYDM } from "../../mocks/MockRecordingYDM.sol";
import { FixedRateAccountantTestBase } from "../../utils/FixedRateAccountantTestBase.sol";

/**
 * @title Test_AccessControl_FixedRateAccountant
 * @notice The fixed rate accountant's caller gates: the onlyRoycoKernel surface, the restricted setter surface for
 *         an unauthorized caller, the unconditionally rejected junior tranche protocol fee setter, and the
 *         sync-before-body ordering contract of the hard-sync setters (including the reverting-kernel recovery
 *         path reserved for the LPT YDM setter)
 */
contract Test_AccessControl_FixedRateAccountant is FixedRateAccountantTestBase {
    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(_defaultParams());
    }

    /// preOpSyncTrancheAccounting reverts for any non-kernel caller, including the admin
    function test_RevertIf_PreOpSyncFromNonKernel() public {
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.preOpSyncTrancheAccounting(toNAVUnits(uint256(1e18)));
        vm.prank(stranger);
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.preOpSyncTrancheAccounting(toNAVUnits(uint256(1e18)));
    }

    /// commitLiquidityProviderTrancheRawNAV reverts for any non-kernel caller, including the admin
    function test_RevertIf_CommitFromNonKernel() public {
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.commitLiquidityProviderTrancheRawNAV(toNAVUnits(uint256(1e18)));
        vm.prank(stranger);
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.commitLiquidityProviderTrancheRawNAV(toNAVUnits(uint256(1e18)));
    }

    /// postOpSyncTrancheAccounting reverts for any non-kernel caller, including the admin
    function test_RevertIf_PostOpSyncFromNonKernel() public {
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, toNAVUnits(uint256(1e18)), ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        vm.prank(stranger);
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, toNAVUnits(uint256(1e18)), ZERO_NAV_UNITS, ZERO_NAV_UNITS);
    }

    /// all 11 restricted setters (plus inherited pause/unpause) revert AccessManagedUnauthorized for a role-less caller
    function test_RevertIf_UnauthorizedCallerOnAllSetters() public {
        bytes[] memory calls = new bytes[](13);
        bytes[] memory hardSync = _hardSyncSetterCalls();
        for (uint256 i; i < 10; ++i) {
            calls[i] = hardSync[i];
        }
        calls[10] = abi.encodeCall(IRoycoDayFixedRateAccountant.setLiquidityProviderTrancheYDM, (address(0xBEEF), bytes("")));
        calls[11] = abi.encodeCall(IRoycoAuth.pause, ());
        calls[12] = abi.encodeCall(IRoycoAuth.unpause, ());
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
            (bool success,) = address(accountant).call(calls[i]);
            success;
        }
    }

    /// setJuniorTrancheProtocolFee is rejected unconditionally for every caller: the override carries no modifiers,
    /// so both the stranger and the admin hit the flavor's INVALID_PROTOCOL_FEE_CONFIG pin, never the auth gate
    function test_RevertIf_SetJuniorTrancheProtocolFeeForEveryone() public {
        bytes32 preHash = _stateHash();
        vm.prank(stranger);
        vm.expectRevert(IRoycoDayFixedRateAccountant.INVALID_PROTOCOL_FEE_CONFIG.selector);
        accountant.setJuniorTrancheProtocolFee(0);
        vm.expectRevert(IRoycoDayFixedRateAccountant.INVALID_PROTOCOL_FEE_CONFIG.selector);
        accountant.setJuniorTrancheProtocolFee(uint64(0.2e18));
        assertEq(_stateHash(), preHash, "the pinned setter may never mutate state");
    }

    /// each of the 10 hard-sync setters brackets its body with kernel syncs: one observing the pre-call state before
    /// the body runs, and one observing the mutated state after, so the config guard always judges the new parameters
    function test_SetterSync_hardSyncSettersBracketBodyWithSyncs() public {
        bytes[] memory calls = _hardSyncSetterCalls();
        for (uint256 i; i < calls.length; ++i) {
            uint256 countBefore = kernel.syncCallCount();
            bytes32 preHash = _stateHash();
            (bool success,) = address(accountant).call(calls[i]);
            assertTrue(success, "setter must succeed");
            assertEq(kernel.syncCallCount(), countBefore + 2, "kernel sync not attempted exactly twice");
            assertEq(kernel.stateHashAtSync(countBefore), preHash, "the first sync must observe the pre-body state");
            bytes32 postHash = _stateHash();
            assertTrue(postHash != preHash, "setter body must have mutated state");
            assertEq(kernel.stateHashAtSync(countBefore + 1), postHash, "the second sync must observe the mutated state the guard judges");
        }
    }

    /// a REVERT-mode kernel bricks all 10 hard-sync setters
    function test_SetterSync_revertingKernelBricksHardSyncSetters() public {
        kernel.setSyncMode(MockFixedRateAccountantKernel.SyncMode.REVERT);
        bytes[] memory calls = _hardSyncSetterCalls();
        bytes32 preHash = _stateHash();
        for (uint256 i; i < calls.length; ++i) {
            vm.expectRevert(MockFixedRateAccountantKernel.KERNEL_SYNC_REVERTED.selector);
            (bool success,) = address(accountant).call(calls[i]);
            success;
        }
        assertEq(_stateHash(), preHash, "no setter body may have executed");
    }

    /// the LPT YDM setter tolerates a reverting kernel sync (the recovery path from a sync-bricking YDM)
    function test_SetterSync_ydmSetterToleratesRevertingKernel() public {
        kernel.setSyncMode(MockFixedRateAccountantKernel.SyncMode.REVERT);
        MockRecordingYDM newLPT = new MockRecordingYDM();
        accountant.setLiquidityProviderTrancheYDM(address(newLPT), "");
        assertEq(accountant.getRoycoDayFixedRateAccountantState().lptYDM, address(newLPT), "lpt ydm updated despite reverting kernel");
    }

    /// the tolerated kernel sync is still attempted by the LPT YDM setter (counted in NONE mode)
    function test_SetterSync_ydmSetterAttemptsKernelSync() public {
        uint256 countBefore = kernel.syncCallCount();
        MockRecordingYDM newLPT = new MockRecordingYDM();
        accountant.setLiquidityProviderTrancheYDM(address(newLPT), "");
        assertEq(kernel.syncCallCount(), countBefore + 1, "lpt setter attempted the sync");
    }
}
