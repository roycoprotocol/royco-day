// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { console2 } from "../../lib/forge-std/src/console2.sol";
import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IAccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CREATE3 } from "../../lib/solady/src/utils/CREATE3.sol";
import { RoycoDayEntryPoint } from "../../src/entrypoint/RoycoDayEntryPoint.sol";
import {
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE,
    ADMIN_PAUSER_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    JT_LP_ROLE,
    LT_LP_ROLE,
    PUBLIC_ROLE,
    ST_LP_ROLE
} from "../../src/factory/RolesConfiguration.sol";
import { IRoycoAuth } from "../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayEntryPoint } from "../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoFactory } from "../../src/interfaces/factory/IRoycoFactory.sol";
import { EntryPointDeploymentConfig } from "../config/EntryPointDeploymentConfig.sol";
import { AccessManagerConfigUtils } from "../utils/AccessManagerConfigUtils.sol";
import { Create2DeployUtils } from "../utils/Create2DeployUtils.sol";

/**
 * @title DeployEntryPointScript
 * @notice Deployment script for the RoycoDayEntryPoint contract
 * @dev Deploys both the implementation and ERC1967 proxy using deterministic CREATE2/CREATE3 deployment,
 *      then initializes the proxy with the per-chain tranche configuration. Access manager role
 *      configuration is generated separately via `buildAccessConfigTransactions` and applied
 *      through a Safe transaction batch targeting the factory's ROYCO_AUTHORITY.
 */
contract DeployEntryPointScript is EntryPointDeploymentConfig, AccessManagerConfigUtils, Create2DeployUtils {
    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deployment salt for the RoycoDayEntryPoint (distinct from dawn's entry point salt)
    bytes32 internal constant ENTRY_POINT_SALT_BASE = keccak256("ROYCO_DAY_ENTRY_POINT_PRODUCTION");

    /// @dev Suffix for the Safe transaction JSON file name
    string internal constant SAFE_TX_OUTPUT_FILE_NAME_SUFFIX = "_entry_point_role_config";

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT FLAGS
    // ═══════════════════════════════════════════════════════════════════════════

    bool internal ENABLE_LOGGING = false;

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Production deployment entry point
     * @dev Deploys the entry point only. Access manager role configuration must be done
     *      separately via Safe transaction batches.
     *
     * Environment variables:
     *   DEPLOYER_PRIVATE_KEY - Key for the deployer account (CREATE2 deployment)
     */
    function run() external {
        ENABLE_LOGGING = true;

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        EntryPointConfig memory config = getEntryPointConfig();
        require(config.roycoFactory != address(0), "Chain not supported");

        address accessManager = IRoycoFactory(config.roycoFactory).ROYCO_AUTHORITY();
        address entryPoint = deployEntryPoint(config, deployerPrivateKey);

        // Write the Safe JSON containing the access manager role-config batch
        writeAccessConfigSafeJson(accessManager, entryPoint);

        // Simulate applying the batch + verify FNDN, WCE, and factory access. Cheatcodes are local-only
        // (no on-chain effect), so this is safe to run alongside the deploy broadcast.
        simulateAccessConfig(accessManager, config.roycoFactory, entryPoint);

        if (ENABLE_LOGGING) {
            console2.log("");
            console2.log("========================================");
            console2.log("Entry Point deployed at:", entryPoint);
            console2.log("Factory:", config.roycoFactory);
            console2.log("Access Manager:", accessManager);
            console2.log("Chain:", config.chainId);
            console2.log("Tranches configured:", config.tranches.length);
            console2.log("========================================");
            console2.log("");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploys a RoycoDayEntryPoint implementation and proxy via CREATE2/CREATE3
     * @param _config The entry point deployment configuration
     * @param _deployerPrivateKey The private key for executing the deployment
     * @return entryPoint The address of the deployed entry point proxy
     */
    function deployEntryPoint(EntryPointConfig memory _config, uint256 _deployerPrivateKey) public returns (address entryPoint) {
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory trancheConfigs) = _unpackTrancheConfigs(_config);

        vm.startBroadcast(_deployerPrivateKey);

        // Deploy the implementation with the factory baked into its immutable state
        bytes memory implCreationCode = abi.encodePacked(type(RoycoDayEntryPoint).creationCode, abi.encode(_config.roycoFactory));
        (address implAddr, bool alreadyDeployed) = deployWithSanityChecks(ENTRY_POINT_SALT_BASE, implCreationCode, true);
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) console2.log("EntryPoint Implementation already deployed at:", implAddr);
            else console2.log("EntryPoint Implementation deployed at:", implAddr);
        }

        bytes memory initData = abi.encodeCall(RoycoDayEntryPoint.initialize, (tranches, trancheConfigs));
        bytes memory proxyCreationCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implAddr, initData));
        entryPoint = CREATE3.deployDeterministic(proxyCreationCode, ENTRY_POINT_SALT_BASE);
        if (ENABLE_LOGGING) console2.log("EntryPoint Proxy deployed at:", entryPoint);

        vm.stopBroadcast();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SAFE TRANSACTION BUILDERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Builds the Safe transactions needed to configure access manager roles for the entry point
     * @dev Returns the transactions without writing them. Can be used by future Safe batch generation.
     * @param _accessManager The Royco authority (AccessManager) address
     * @param _entryPoint The deployed entry point proxy address
     * @return transactions Array of Safe transactions to execute
     */
    function buildAccessConfigTransactions(address _accessManager, address _entryPoint) public view returns (SafeTransaction[] memory transactions) {
        bytes4[] memory lpSelectors = _buildLPSelectors();

        bytes4[] memory adminSelectors = new bytes4[](1);
        adminSelectors[0] = IRoycoDayEntryPoint.modifyTrancheConfigs.selector;

        bytes4[] memory entryPointClaimFeeSelectors = new bytes4[](1);
        entryPointClaimFeeSelectors[0] = IRoycoDayEntryPoint.collectProtocolFees.selector;

        bytes4[] memory pauseSelectors = new bytes4[](1);
        pauseSelectors[0] = IRoycoAuth.pause.selector;

        bytes4[] memory unpauseSelectors = new bytes4[](1);
        unpauseSelectors[0] = IRoycoAuth.unpause.selector;

        bytes4[] memory upgraderSelectors = new bytes4[](1);
        upgraderSelectors[0] = UUPSUpgradeable.upgradeToAndCall.selector;

        // 6 setTargetFunctionRole + 6 grantRole = 12 total
        //   - LP -> PUBLIC_ROLE
        //   - modifyTrancheConfigs   -> ADMIN_ENTRY_POINT_ROLE (Standard 24h; the factory already holds it at 0 delay from its init)
        //   - collectProtocolFees    -> ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE (Immediate)
        //   - pause / unpause / upgrade -> respective roles
        //   - grant ADMIN_ENTRY_POINT_ROLE to ROOT_MULTISIG (Standard) and WCE_MULTISIG (Immediate)
        //   - grant ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE to ROOT_MULTISIG (Immediate)
        //   - grant ST_LP_ROLE / JT_LP_ROLE / LT_LP_ROLE to the entry point itself
        transactions = new SafeTransaction[](12);
        transactions[0] = buildSetTargetFunctionRole(_accessManager, _entryPoint, lpSelectors, PUBLIC_ROLE);
        transactions[1] = buildSetTargetFunctionRole(_accessManager, _entryPoint, adminSelectors, ADMIN_ENTRY_POINT_ROLE);
        transactions[2] = buildSetTargetFunctionRole(_accessManager, _entryPoint, entryPointClaimFeeSelectors, ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE);
        transactions[3] = buildSetTargetFunctionRole(_accessManager, _entryPoint, pauseSelectors, ADMIN_PAUSER_ROLE);
        transactions[4] = buildSetTargetFunctionRole(_accessManager, _entryPoint, unpauseSelectors, ADMIN_UNPAUSER_ROLE);
        transactions[5] = buildSetTargetFunctionRole(_accessManager, _entryPoint, upgraderSelectors, ADMIN_UPGRADER_ROLE);
        // Grant ADMIN_ENTRY_POINT_ROLE to ROOT_MULTISIG with the configured Standard delay
        transactions[6] = buildGrantRole(_accessManager, ADMIN_ENTRY_POINT_ROLE, ROOT_MULTISIG, 24 hours);
        // Grant ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE to ROOT_MULTISIG (Immediate)
        transactions[7] = buildGrantRole(_accessManager, ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE, ROOT_MULTISIG, 0);
        // Grant ADMIN_ENTRY_POINT_ROLE to WCE_MULTISIG with immediate delay
        transactions[8] = buildGrantRole(_accessManager, ADMIN_ENTRY_POINT_ROLE, WCE_MULTISIG, 0);
        // The entry point itself needs LP roles to call tranche.deposit/redeem (and to receive escrowed shares on
        // whitelist-enforcing markets)
        transactions[9] = buildGrantRole(_accessManager, ST_LP_ROLE, _entryPoint, 0);
        transactions[10] = buildGrantRole(_accessManager, JT_LP_ROLE, _entryPoint, 0);
        transactions[11] = buildGrantRole(_accessManager, LT_LP_ROLE, _entryPoint, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SAFE JSON COMPOSITION + SIMULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Composes the access manager role-config Safe batch and writes it to disk.
     * @param _accessManager The Royco authority (AccessManager) address
     * @param _entryPoint The deployed entry point proxy address
     */
    function writeAccessConfigSafeJson(address _accessManager, address _entryPoint) public {
        SafeTransaction[] memory txs = buildAccessConfigTransactions(_accessManager, _entryPoint);
        string memory fileName = string.concat(vm.toString(block.chainid), SAFE_TX_OUTPUT_FILE_NAME_SUFFIX);
        writeSafeTransactionJson(
            txs, fileName, "Royco Day Entry Point Role Configuration", "Sets up the role configuration for the Royco Day Entry Point on the Royco AccessManager"
        );
        if (ENABLE_LOGGING) console2.log("Wrote access config Safe JSON:", fileName);
    }

    /**
     * @notice Simulates applying the role-config batch on a fork and asserts that
     *         FNDN (`ROOT_MULTISIG`), WCE (`WCE_MULTISIG`), and the factory can call the
     *         entry point's admin functions per the security model:
     *
     *           - WCE  -> `modifyTrancheConfigs` directly (Immediate, delay 0)
     *           - WCE  -> `collectProtocolFees`         REVERT (no claim-fee role)
     *           - FNDN -> `modifyTrancheConfigs` directly REVERT (Standard delay required)
     *           - FNDN -> `modifyTrancheConfigs` via schedule + 24h + execute -> SUCCESS
     *           - FNDN -> `collectProtocolFees`        directly -> SUCCESS (Immediate)
     *           - Factory -> `modifyTrancheConfigs` directly -> SUCCESS (holds ADMIN_ENTRY_POINT_ROLE
     *             at 0 delay from its initialization, the template auto-enable path)
     *
     *         Uses cheatcodes (vm.prank, vm.warp) — these are local-only and do not affect
     *         the broadcast.
     * @param _accessManager The Royco authority (AccessManager) address
     * @param _factory The Royco factory address
     * @param _entryPoint The deployed entry point proxy address
     */
    function simulateAccessConfig(address _accessManager, address _factory, address _entryPoint) public {
        SafeTransaction[] memory txs = buildAccessConfigTransactions(_accessManager, _entryPoint);

        // Apply each batch tx as ROOT_MULTISIG (admin role 0). On a fresh access manager ROOT_MULTISIG
        // has 0 delay on role 0, so direct calls work; a live deployment with a delayed admin applies
        // the batch via a separate schedule+execute and is out of scope here.
        for (uint256 i = 0; i < txs.length; i++) {
            vm.prank(ROOT_MULTISIG);
            (bool ok, bytes memory ret) = txs[i].to.call{ value: txs[i].value }(txs[i].data);
            require(ok, _decodeRevert(ret, i));
        }

        // OZ AccessManager schedules a grace period for delay reductions; warp past it.
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);

        // Build empty-config calldata for both admin functions (zero-tranche updates / zero-fee
        // collections; just exercising authorization, not state mutation).
        address[] memory emptyTranches = new address[](0);
        IRoycoDayEntryPoint.TrancheConfig[] memory emptyConfigs = new IRoycoDayEntryPoint.TrancheConfig[](0);
        bytes memory modifyData = abi.encodeCall(IRoycoDayEntryPoint.modifyTrancheConfigs, (emptyTranches, emptyConfigs));

        uint256[] memory emptyShares = new uint256[](0);
        bytes memory claimFeeData = abi.encodeCall(IRoycoDayEntryPoint.collectProtocolFees, (emptyTranches, emptyShares, ROOT_MULTISIG));

        // ── 1. WCE -> modifyTrancheConfigs directly (Immediate)
        vm.prank(WCE_MULTISIG);
        (bool wceOk,) = _entryPoint.call(modifyData);
        require(wceOk, "WCE should call modifyTrancheConfigs immediately");

        // ── 2. WCE -> collectProtocolFees should revert (no claim-fee role)
        vm.prank(WCE_MULTISIG);
        (bool wceFeeOk,) = _entryPoint.call(claimFeeData);
        require(!wceFeeOk, "WCE must NOT have claim-fee role");

        // ── 3. FNDN -> modifyTrancheConfigs directly should revert (delay required)
        vm.prank(ROOT_MULTISIG);
        (bool fndnDirect,) = _entryPoint.call(modifyData);
        require(!fndnDirect, "FNDN direct modifyTrancheConfigs must revert (Standard delay)");

        // ── 4. FNDN -> schedule + 1d + execute modifyTrancheConfigs (Standard)
        vm.prank(ROOT_MULTISIG);
        IAccessManager(_accessManager).schedule(_entryPoint, modifyData, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(ROOT_MULTISIG);
        IAccessManager(_accessManager).execute(_entryPoint, modifyData);

        // ── 5. FNDN -> collectProtocolFees directly (Immediate via claim-fee role)
        vm.prank(ROOT_MULTISIG);
        (bool fndnFeeOk,) = _entryPoint.call(claimFeeData);
        require(fndnFeeOk, "FNDN should call collectProtocolFees immediately");

        // ── 6. Factory -> modifyTrancheConfigs directly (the template auto-enable path)
        vm.prank(_factory);
        (bool factoryOk,) = _entryPoint.call(modifyData);
        require(factoryOk, "Factory should call modifyTrancheConfigs immediately (init-time ADMIN_ENTRY_POINT_ROLE grant)");

        if (ENABLE_LOGGING) {
            console2.log("");
            console2.log("[OK] Access config simulated and access verified:");
            console2.log("     WCE  modifyTrancheConfigs (immediate)         : passed");
            console2.log("     WCE  collectProtocolFees   (must revert)      : passed");
            console2.log("     FNDN modifyTrancheConfigs direct (must revert): passed");
            console2.log("     FNDN modifyTrancheConfigs via schedule+exec   : passed");
            console2.log("     FNDN collectProtocolFees   (immediate)        : passed");
            console2.log("     Factory modifyTrancheConfigs (immediate)      : passed");
        }
    }

    function _decodeRevert(bytes memory _ret, uint256 _i) internal pure returns (string memory) {
        if (_ret.length >= 4) {
            return string.concat("Access config tx ", vm.toString(_i), " reverted; selector=0x", _bytes4ToHex(bytes4(_ret)));
        }
        return string.concat("Access config tx ", vm.toString(_i), " reverted");
    }

    function _bytes4ToHex(bytes4 _b) internal pure returns (string memory) {
        bytes memory hexAlphabet = "0123456789abcdef";
        bytes memory out = new bytes(8);
        for (uint256 i = 0; i < 4; i++) {
            uint8 b = uint8(_b[i]);
            out[2 * i] = hexAlphabet[b >> 4];
            out[2 * i + 1] = hexAlphabet[b & 0x0f];
        }
        return string(out);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildLPSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](11);
        selectors[0] = IRoycoDayEntryPoint.requestDeposit.selector;
        selectors[1] = IRoycoDayEntryPoint.executeDeposit.selector;
        selectors[2] = IRoycoDayEntryPoint.executeDeposits.selector;
        selectors[3] = IRoycoDayEntryPoint.cancelDepositRequest.selector;
        selectors[4] = IRoycoDayEntryPoint.cancelDepositRequests.selector;
        selectors[5] = IRoycoDayEntryPoint.requestRedemption.selector;
        selectors[6] = IRoycoDayEntryPoint.executeRedemption.selector;
        selectors[7] = IRoycoDayEntryPoint.executeRedemptions.selector;
        selectors[8] = IRoycoDayEntryPoint.cancelRedemptionRequest.selector;
        selectors[9] = IRoycoDayEntryPoint.cancelRedemptionRequests.selector;
        selectors[10] = IRoycoDayEntryPoint.pokeOracleClock.selector;
    }

    /// @dev Unpacks TrancheInitConfig[] into separate arrays for the initialize call
    function _unpackTrancheConfigs(EntryPointConfig memory _config)
        internal
        pure
        returns (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs)
    {
        uint256 len = _config.tranches.length;
        tranches = new address[](len);
        configs = new IRoycoDayEntryPoint.TrancheConfig[](len);
        for (uint256 i = 0; i < len; i++) {
            tranches[i] = _config.tranches[i].tranche;
            configs[i] = _config.tranches[i].config;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIG INITIALIZATION (override to set deployment parameters)
    // ═══════════════════════════════════════════════════════════════════════════

    function _initializeEntryPointConfigs() internal virtual override {
        // TODO: populate per-chain configs once the Day factory and its first markets are live, e.g.:
        //   EntryPointConfig storage mainnet = _entryPointConfigs[MAINNET];
        //   mainnet.chainId = MAINNET;
        //   mainnet.roycoFactory = ROYCO_FACTORY;
        //   _addMarketTranches(mainnet, ST_ADDRESS, JT_ADDRESS, LT_ADDRESS);
    }
}
