// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { ADMIN_FACTORY_ROLE, ADMIN_ORACLE_ROLE, GUARDIAN_ROLE } from "../../../src/factory/Roles.sol";
import { BaseDeploymentTemplate } from "../../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { TAG_LDM, TAG_YDM } from "../../../src/factory/templates/base/Constants.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { DeployScriptBase } from "../../deploy/core/DeployScriptBase.sol";
import { YDMLib } from "../../deploy/utils/YDMLib.sol";
import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title AddAdaptiveCurveV2SpeedYDMs
 * @notice Installs the AdaptiveCurveYDM_V2 speed grid (10 through 100 per-year, in steps of 10) on the live Day
 *         template on every deployed chain, in ONE 72h cycle — ADMIN_FACTORY_ROLE is memberless on the live chains,
 *         so the flow bootstraps it and installs the models atomically:
 *           1. deploys the model instances permissionlessly (the 100/year pair reuses the live canonical instances);
 *           2. SCHEDULE batch (FNDN Safe, now): schedules five AM admin ops through FNDN's 72h ADMIN_ROLE lockdown —
 *              grant FNDN the factory role at 0 delay (temporary), grant WAY at 72h, point GUARDIAN_ROLE as the
 *              factory role's guardian, move FNDN's oracle co-hold to 72h, and re-grant FNDN's factory seat at 72h;
 *           3. EXECUTE batch (FNDN Safe, after 72h, ONE ATOMIC TX): executes the temporary FNDN grant, performs all
 *              ten `setYieldDistributionModels` registrations DIRECTLY under that fresh 0-delay membership, executes
 *              WAY's standing grant, the guardian pointer, and the oracle co-hold retrofit, then re-grants FNDN at
 *              72h — a delay INCREASE applies immediately, so FNDN's fast factory seat exists only inside this
 *              transaction.
 *         The cancel batch cancels all five scheduled ops (the abort lever during the 72h window).
 * @dev An AccessManager cannot schedule a self-multicall (the selector carries no admin restriction), so the atomic
 *      unit is the Safe execute-batch, not a single scheduled op — MultiSendCallOnly reverts the whole batch if any
 *      inner call fails. SINGLE-USE: this script carries the entire live-chain retrofit (factory role + oracle
 *      co-hold) plus the YDM installation; nothing else needs to run before or after it.
 *      Usage (needs DEPLOYER_PRIVATE_KEY + the four RPC URLs; add `--broadcast --multi` to actually deploy the models):
 *        forge script script/update/template/AddAdaptiveCurveV2SpeedYDMs.s.sol
 */
contract AddAdaptiveCurveV2SpeedYDMs is ParameterUpdateBase, DeployScriptBase {
    uint32 internal constant DELAY_ROOT = 72 hours;

    string internal constant OUTPUT_SUBDIR = "template";
    string internal constant OUTPUT_PREFIX = "add_v2_speed_ydms";
    string internal constant BATCH_DESCRIPTION = "Install the AdaptiveCurveYDM_V2 speed grid (10-100/year) + factory-role setup";

    function run() external {
        uint256[] memory chainIds = new uint256[](4);
        chainIds[0] = MAINNET;
        chainIds[1] = ARBITRUM;
        chainIds[2] = BASE;
        chainIds[3] = AVALANCHE;

        for (uint256 c = 0; c < chainIds.length; ++c) {
            _processYdmInstallation(chainIds[c]);
        }
    }

    /// @notice Forks `_chainId`, deploys the models, simulates the full schedule -> warp -> atomic-execute flow, and
    ///         writes the FNDN Safe batches
    function _processYdmInstallation(uint256 _chainId) internal {
        vm.createSelectFork(_getRpcUrl(_chainId));
        address template = dayTemplate(_chainId);

        console2.log("");
        console2.log("========================================");
        console2.log("Processing chain:", _chainId);
        console2.log("========================================");

        // 1. Deploy (or reuse) the speed grid's model instances under the deployer's broadcast (the 100/year pair
        //    always reuses the canonical instances already live on bootstrapped chains)
        uint256[10] memory speeds = YDMLib.adaptiveV2SpeedVariantsPerYear();
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        for (uint256 i; i < speeds.length; ++i) {
            _deployVariant(speeds[i], TAG_YDM, "JT model  ");
            _deployVariant(speeds[i], TAG_LDM, "LPT model ");
        }
        vm.stopBroadcast();

        // 2. The five AM admin ops FNDN schedules through its 72h ADMIN_ROLE lockdown
        bytes[] memory amOps = _amOps();

        // 3. The ten registration calls FNDN performs DIRECTLY inside the atomic execute batch
        bytes[] memory registrations = new bytes[](speeds.length);
        for (uint256 i; i < speeds.length; ++i) {
            (address jtYdm, address lptYdm) = _predictVariantPair(speeds[i]);
            registrations[i] = abi.encodeCall(BaseDeploymentTemplate.setYieldDistributionModels, (YDMLib.adaptiveV2VariantName(speeds[i]), jtYdm, lptYdm));
        }

        // 4. Simulate the whole flow end-to-end on the fork before writing anything
        _simulateFlow(template, amOps, registrations);

        // 5. Write the FNDN Safe batches
        SafeTransaction[] memory scheduleTxs = new SafeTransaction[](amOps.length);
        SafeTransaction[] memory cancelTxs = new SafeTransaction[](amOps.length);
        for (uint256 i; i < amOps.length; ++i) {
            scheduleTxs[i] =
                SafeTransaction({ to: ACCESS_MANAGER, value: 0, data: abi.encodeCall(IAccessManager.schedule, (ACCESS_MANAGER, amOps[i], uint48(0))) });
            cancelTxs[i] = SafeTransaction({ to: ACCESS_MANAGER, value: 0, data: abi.encodeCall(IAccessManager.cancel, (FNDN, ACCESS_MANAGER, amOps[i])) });
        }

        // The atomic execute batch, in dependency order: temporary FNDN seat -> direct registrations -> standing
        // grants + guardian -> FNDN lockdown re-grant LAST
        SafeTransaction[] memory executeTxs = new SafeTransaction[](registrations.length + amOps.length);
        uint256 t;
        executeTxs[t++] = _executeTx(amOps[0]);
        for (uint256 i; i < registrations.length; ++i) {
            executeTxs[t++] = SafeTransaction({ to: template, value: 0, data: registrations[i] });
        }
        for (uint256 i = 1; i < amOps.length; ++i) {
            executeTxs[t++] = _executeTx(amOps[i]);
        }

        vm.createDir(string.concat(UPDATE_OUTPUT_DIRECTORY, OUTPUT_SUBDIR), true);
        string memory fileBase = string.concat(OUTPUT_SUBDIR, "/", vm.toString(_chainId), "_", OUTPUT_PREFIX);
        _writeUpdateSafeTransactionJson(scheduleTxs, string.concat(fileBase, "_schedule"), BATCH_DESCRIPTION, string.concat(BATCH_DESCRIPTION, " (schedule)"));
        _writeUpdateSafeTransactionJson(
            executeTxs, string.concat(fileBase, "_execute"), BATCH_DESCRIPTION, string.concat(BATCH_DESCRIPTION, " (execute - ONE atomic batch)")
        );
        _writeUpdateSafeTransactionJson(cancelTxs, string.concat(fileBase, "_cancel"), BATCH_DESCRIPTION, string.concat(BATCH_DESCRIPTION, " (cancel)"));

        console2.log("  Output:", string.concat(UPDATE_OUTPUT_DIRECTORY, fileBase, "_*.json"));
        console2.log("  Scheduled AM ops:", amOps.length, " Direct registrations:", registrations.length);
    }

    /// @dev The five AM admin ops, in the execute batch's order (index 0 MUST run before the registrations, the
    ///      final FNDN re-grant MUST run last)
    function _amOps() internal pure returns (bytes[] memory amOps) {
        amOps = new bytes[](5);
        // Temporary: FNDN takes the factory role at 0 execution delay, only to act inside the atomic batch
        amOps[0] = abi.encodeCall(IAccessManager.grantRole, (ADMIN_FACTORY_ROLE, FNDN, 0));
        // Standing: WAY's factory-admin seat at the root delay
        amOps[1] = abi.encodeCall(IAccessManager.grantRole, (ADMIN_FACTORY_ROLE, WAY, DELAY_ROOT));
        // The factory role becomes veto-cancellable like WAY's other roles
        amOps[2] = abi.encodeCall(IAccessManager.setRoleGuardian, (ADMIN_FACTORY_ROLE, GUARDIAN_ROLE));
        // Role-graph retrofit riding along: FNDN's oracle co-hold moves from 0 delay to the table's 72h
        amOps[3] = abi.encodeCall(IAccessManager.grantRole, (ADMIN_ORACLE_ROLE, FNDN, DELAY_ROOT));
        // Lockdown: re-granting FNDN at the root delay is a delay INCREASE, which applies immediately
        amOps[4] = abi.encodeCall(IAccessManager.grantRole, (ADMIN_FACTORY_ROLE, FNDN, DELAY_ROOT));
    }

    function _executeTx(bytes memory _op) internal pure returns (SafeTransaction memory) {
        return SafeTransaction({ to: ACCESS_MANAGER, value: 0, data: abi.encodeCall(IAccessManager.execute, (ACCESS_MANAGER, _op)) });
    }

    /// @dev Simulates the exact submission flow: FNDN schedules the four ops, time passes, then the atomic execute
    ///      batch runs in order. Verifies the registrations and the end-state role distribution.
    function _simulateFlow(address _template, bytes[] memory _amOps, bytes[] memory _registrations) internal {
        IAccessManager am = IAccessManager(ACCESS_MANAGER);

        vm.startPrank(FNDN);
        bytes32 firstOpId;
        for (uint256 i; i < _amOps.length; ++i) {
            (bytes32 operationId,) = am.schedule(ACCESS_MANAGER, _amOps[i], uint48(0));
            if (i == 0) firstOpId = operationId;
        }
        console2.log("  [OK] Schedule batch (5 AM ops, authorization validated)");

        uint48 executableAt = am.getSchedule(firstOpId);
        require(executableAt != 0, VerificationFailed("schedule did not register"));
        vm.warp(uint256(executableAt));

        // The atomic execute batch, in the exact order the Safe will submit it
        am.execute(ACCESS_MANAGER, _amOps[0]);
        for (uint256 i; i < _registrations.length; ++i) {
            (bool ok, bytes memory ret) = _template.call(_registrations[i]);
            if (!ok) {
                console2.logBytes(ret);
                revert VerificationFailed("direct registration reverted");
            }
        }
        for (uint256 i = 1; i < _amOps.length; ++i) {
            am.execute(ACCESS_MANAGER, _amOps[i]);
        }
        vm.stopPrank();
        console2.log("  [OK] Execute batch (temp seat -> 10 registrations -> standing grants -> lockdown)");

        // End state: every registration landed with the right instance + speed...
        for (uint256 i; i < _registrations.length; ++i) {
            _verify(UpdateParams({ marketName: "", target: _template, callData: _registrations[i], description: "" }));
        }
        // ...and the role distribution matches the target graph: WAY and FNDN both at the root delay
        (bool wayMember, uint32 wayDelay) = am.hasRole(ADMIN_FACTORY_ROLE, WAY);
        require(wayMember && wayDelay == DELAY_ROOT, VerificationFailed("WAY factory seat not at the root delay"));
        (bool fndnMember, uint32 fndnDelay) = am.hasRole(ADMIN_FACTORY_ROLE, FNDN);
        require(fndnMember && fndnDelay == DELAY_ROOT, VerificationFailed("FNDN factory seat not locked back down"));
        require(am.getRoleGuardian(ADMIN_FACTORY_ROLE) == GUARDIAN_ROLE, VerificationFailed("factory role guardian not set"));
        (bool oracleMember, uint32 oracleDelay) = am.hasRole(ADMIN_ORACLE_ROLE, FNDN);
        require(oracleMember && oracleDelay == DELAY_ROOT, VerificationFailed("FNDN oracle co-hold not at the root delay"));
        console2.log("  [OK] Verification (registrations + end-state roles)");
    }

    /// @dev The chain-agnostic CREATE2 predictions for a speed variant's JT/LPT instance pair
    function _predictVariantPair(uint256 _speedPerYear) internal pure returns (address jtYdm, address lptYdm) {
        bytes memory initCode = abi.encodePacked(
            type(AdaptiveCurveYDM_V2).creationCode, YDMLib.adaptiveV2VariantConstructorArgs(YDMLib.YDM_TARGET_UTILIZATION_WAD, _speedPerYear)
        );
        jtYdm = generateDeterminsticAddress(YDMLib.adaptiveV2VariantSalt(TAG_YDM, _speedPerYear), initCode);
        lptYdm = generateDeterminsticAddress(YDMLib.adaptiveV2VariantSalt(TAG_LDM, _speedPerYear), initCode);
    }

    function _deployVariant(uint256 _speedPerYear, bytes32 _slotTag, string memory _label) internal {
        (address model, bool existed) = deployWithSanityChecks(
            YDMLib.adaptiveV2VariantSalt(_slotTag, _speedPerYear),
            abi.encodePacked(type(AdaptiveCurveYDM_V2).creationCode, YDMLib.adaptiveV2VariantConstructorArgs(YDMLib.YDM_TARGET_UTILIZATION_WAD, _speedPerYear)),
            false
        );
        console2.log(string.concat(existed ? "  [reused]   " : "  [deployed] ", _label, "V2 speed ", vm.toString(_speedPerYear)), model);
    }

    /// @inheritdoc ParameterUpdateBase
    function _verify(UpdateParams memory _params) internal view override {
        uint256[10] memory speeds = YDMLib.adaptiveV2SpeedVariantsPerYear();
        for (uint256 i; i < speeds.length; ++i) {
            string memory name = YDMLib.adaptiveV2VariantName(speeds[i]);
            (address jtYdm, address lptYdm) = _predictVariantPair(speeds[i]);
            if (keccak256(_params.callData) != keccak256(abi.encodeCall(BaseDeploymentTemplate.setYieldDistributionModels, (name, jtYdm, lptYdm)))) {
                continue;
            }
            BaseDeploymentTemplate t = BaseDeploymentTemplate(_params.target);
            require(t.jtYdms(name) == jtYdm, VerificationFailed(string.concat(name, ": JT model not registered")));
            require(t.lptYdms(name) == lptYdm, VerificationFailed(string.concat(name, ": LPT model not registered")));
            // The registered instances must carry the variant's boundary adaptation speed
            uint256 expectedSpeed = speeds[i] * 1e18 / uint256(365 days);
            require(
                AdaptiveCurveYDM_V2(jtYdm).ADAPTATION_SPEED_AT_BOUNDARY_WAD() == expectedSpeed,
                VerificationFailed(string.concat(name, ": JT adaptation speed mismatch"))
            );
            require(
                AdaptiveCurveYDM_V2(lptYdm).ADAPTATION_SPEED_AT_BOUNDARY_WAD() == expectedSpeed,
                VerificationFailed(string.concat(name, ": LPT adaptation speed mismatch"))
            );
            return;
        }
        revert VerificationFailed("unknown operation");
    }
}
