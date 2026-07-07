// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Vm } from "../../lib/forge-std/src/Vm.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import { RoycoDayAccountant } from "../../src/accountant/RoycoDayAccountant.sol";
import { ADMIN_UNPAUSER_ROLE, JT_LP_ROLE, ST_LP_ROLE } from "../../src/factory/RolesConfiguration.sol";
import { RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { IRoycoBlacklist } from "../../src/interfaces/IRoycoBlacklist.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits } from "../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoSeniorTranche } from "../../src/tranches/RoycoSeniorTranche.sol";
import { Assertions } from "./Assertions.sol";

abstract contract RoycoDayTestBase is Test, Assertions {
    uint256 internal constant BPS = 0.0001e18;

    /// @dev The target coverage utilization (the YDM curve kink) used by the JT risk-premium YDMs in tests (90%)
    uint256 internal constant TARGET_COVERAGE_UTILIZATION_WAD = 0.9e18;
    int256 internal constant TARGET_COVERAGE_UTILIZATION_WAD_INT = 0.9e18;

    struct TrancheState {
        NAV_UNIT rawNAV;
        NAV_UNIT effectiveNAV;
        TRANCHE_UNIT stAssetsClaim;
        TRANCHE_UNIT jtAssetsClaim;
        NAV_UNIT protocolFeeValue;
        uint256 totalShares;
    }

    // -----------------------------------------
    // Test Wallets
    // -----------------------------------------
    Vm.Wallet internal OWNER;
    address internal OWNER_ADDRESS;

    // Role-specific wallets
    Vm.Wallet internal PAUSER;
    address internal PAUSER_ADDRESS;

    Vm.Wallet internal UNPAUSER;
    address internal UNPAUSER_ADDRESS;

    Vm.Wallet internal UPGRADER;
    address internal UPGRADER_ADDRESS;

    Vm.Wallet internal SYNC_ROLE_HOLDER;
    address internal SYNC_ROLE_ADDRESS;

    Vm.Wallet internal KERNEL_ADMIN;
    address internal KERNEL_ADMIN_ADDRESS;

    Vm.Wallet internal ACCOUNTANT_ADMIN;
    address internal ACCOUNTANT_ADMIN_ADDRESS;

    Vm.Wallet internal PROTOCOL_FEE_SETTER;
    address internal PROTOCOL_FEE_SETTER_ADDRESS;

    Vm.Wallet internal ORACLE_QUOTER_ADMIN;
    address internal ORACLE_QUOTER_ADMIN_ADDRESS;

    Vm.Wallet internal LP_ROLE_ADMIN;
    address internal LP_ROLE_ADMIN_ADDRESS;

    Vm.Wallet internal ROLE_GUARDIAN;
    address internal ROLE_GUARDIAN_ADDRESS;

    Vm.Wallet internal PROTOCOL_FEE_RECIPIENT;
    address internal PROTOCOL_FEE_RECIPIENT_ADDRESS;

    Vm.Wallet internal DEPLOYER;
    address internal DEPLOYER_ADDRESS;

    Vm.Wallet internal DEPLOYER_ADMIN;
    address internal DEPLOYER_ADMIN_ADDRESS;

    // ST-only providers
    Vm.Wallet internal ST_ALICE;
    Vm.Wallet internal ST_BOB;
    Vm.Wallet internal ST_CHARLIE;
    Vm.Wallet internal ST_DAN;
    address internal ST_ALICE_ADDRESS;
    address internal ST_BOB_ADDRESS;
    address internal ST_CHARLIE_ADDRESS;
    address internal ST_DAN_ADDRESS;

    // JT-only providers
    Vm.Wallet internal JT_ALICE;
    Vm.Wallet internal JT_BOB;
    Vm.Wallet internal JT_CHARLIE;
    Vm.Wallet internal JT_DAN;
    address internal JT_ALICE_ADDRESS;
    address internal JT_BOB_ADDRESS;
    address internal JT_CHARLIE_ADDRESS;
    address internal JT_DAN_ADDRESS;

    address[] internal providers;

    // -----------------------------------------
    // Royco Deployments
    // -----------------------------------------

    // Deploy Script
    DeployScript internal DEPLOY_SCRIPT;

    // Deployments
    RoycoFactory internal FACTORY;
    AccessManager internal ACCESS_MANAGER;
    IYDM internal YDM;
    IRoycoVaultTranche internal ST;
    IRoycoVaultTranche internal JT;
    IRoycoDayKernel internal KERNEL;
    IRoycoDayAccountant internal ACCOUNTANT;
    IRoycoBlacklist internal BLACKLIST;

    // -----------------------------------------
    // Royco Deployments Parameters
    // -----------------------------------------

    string internal SENIOR_TRANCHE_NAME = "Royco Senior Tranche";
    string internal SENIOR_TRANCHE_SYMBOL = "RST";
    string internal JUNIOR_TRANCHE_NAME = "Royco Junior Tranche";
    string internal JUNIOR_TRANCHE_SYMBOL = "RJT";
    uint64 internal COVERAGE_WAD = 0.2e18; // 20% coverage
    bool internal JT_COINVESTED = false; // JT in a different opportunity (RFR), uncorrelated downside
    uint64 internal ST_PROTOCOL_FEE_WAD = 0.1e18; // 10% protocol fee
    uint64 internal JT_PROTOCOL_FEE_WAD = 0.1e18; // 10% protocol fee
    /**
     * @dev Liquidation coverage utilization threshold. Derivation at this fixture's 20% minimum coverage:
     *      coverage utilization is exposure x minCoverage / jtEffectiveNAV (JT not co-invested here, so exposure is
     *      stRawNAV alone), and 97 x 0.2e18 / 3 = 6.4666...e18 is the utilization of a market whose junior buffer
     *      has eroded to 3 NAV units against 97 units of senior exposure. Rounding that up at the fourth decimal
     *      to 6.4667e18 keeps the exact 97-to-3 market just below the threshold, so liquidation arms only once the
     *      junior buffer covers less than ~3.09% (0.2e18 / 6.4667e18) of senior exposure — a near-total JT wipeout,
     *      far above any utilization a healthy seeded state in this suite reads
     */
    uint256 internal LIQUIDATION_COVERAGE_UTILIZATION_WAD = 6.4667e18;
    uint24 internal FIXED_TERM_DURATION_SECONDS = 2 weeks; // 2 weeks in seconds
    NAV_UNIT internal DUST_TOLERANCE = toNAVUnits(uint256(1));

    modifier prankModifier(address _pranker) {
        vm.startPrank(_pranker);
        _;
        vm.stopPrank();
    }

    function _setUpRoyco() internal virtual {
        _setupFork();
        _setupWallets();

        // Deploy the deploy script
        DEPLOY_SCRIPT = new DeployScript();
    }

    function _setupFork() internal {
        (uint256 forkBlock, string memory forkRpcUrl) = _forkConfiguration();
        if (bytes(forkRpcUrl).length > 0) {
            require(forkBlock != 0, "Fork block is required");
            vm.createSelectFork(forkRpcUrl, forkBlock);
        }
    }

    function _setupWallets() internal {
        // Admin wallet
        OWNER = _initWallet("OWNER", 1000 ether);
        OWNER_ADDRESS = OWNER.addr;

        // Role-specific wallets
        PAUSER = _initWallet("PAUSER", 1000 ether);
        PAUSER_ADDRESS = PAUSER.addr;

        UNPAUSER = _initWallet("UNPAUSER", 1000 ether);
        UNPAUSER_ADDRESS = UNPAUSER.addr;

        UPGRADER = _initWallet("UPGRADER", 1000 ether);
        UPGRADER_ADDRESS = UPGRADER.addr;

        SYNC_ROLE_HOLDER = _initWallet("SYNC_ROLE_HOLDER", 1000 ether);
        SYNC_ROLE_ADDRESS = SYNC_ROLE_HOLDER.addr;

        KERNEL_ADMIN = _initWallet("KERNEL_ADMIN", 1000 ether);
        KERNEL_ADMIN_ADDRESS = KERNEL_ADMIN.addr;

        ACCOUNTANT_ADMIN = _initWallet("ACCOUNTANT_ADMIN", 1000 ether);
        ACCOUNTANT_ADMIN_ADDRESS = ACCOUNTANT_ADMIN.addr;

        PROTOCOL_FEE_SETTER = _initWallet("PROTOCOL_FEE_SETTER", 1000 ether);
        PROTOCOL_FEE_SETTER_ADDRESS = PROTOCOL_FEE_SETTER.addr;

        ORACLE_QUOTER_ADMIN = _initWallet("ORACLE_QUOTER_ADMIN", 1000 ether);
        ORACLE_QUOTER_ADMIN_ADDRESS = ORACLE_QUOTER_ADMIN.addr;

        LP_ROLE_ADMIN = _initWallet("LP_ROLE_ADMIN", 1000 ether);
        LP_ROLE_ADMIN_ADDRESS = LP_ROLE_ADMIN.addr;

        ROLE_GUARDIAN = _initWallet("ROLE_GUARDIAN", 1000 ether);
        ROLE_GUARDIAN_ADDRESS = ROLE_GUARDIAN.addr;

        PROTOCOL_FEE_RECIPIENT = _initWallet("PROTOCOL_FEE_RECIPIENT", 1000 ether);
        PROTOCOL_FEE_RECIPIENT_ADDRESS = PROTOCOL_FEE_RECIPIENT.addr;

        // Deployer wallets (for factory deployment)
        DEPLOYER = _initWallet("DEPLOYER", 1000 ether);
        DEPLOYER_ADDRESS = DEPLOYER.addr;

        DEPLOYER_ADMIN = _initWallet("DEPLOYER_ADMIN", 1000 ether);
        DEPLOYER_ADMIN_ADDRESS = DEPLOYER_ADMIN.addr;
    }

    function _setupProviders() internal {
        // ST-only providers
        ST_ALICE = _generateProvider("ST_ALICE", ST_LP_ROLE);
        ST_BOB = _generateProvider("ST_BOB", ST_LP_ROLE);
        ST_CHARLIE = _generateProvider("ST_CHARLIE", ST_LP_ROLE);
        ST_DAN = _generateProvider("ST_DAN", ST_LP_ROLE);

        ST_ALICE_ADDRESS = ST_ALICE.addr;
        ST_BOB_ADDRESS = ST_BOB.addr;
        ST_CHARLIE_ADDRESS = ST_CHARLIE.addr;
        ST_DAN_ADDRESS = ST_DAN.addr;

        // JT-only providers
        JT_ALICE = _generateProvider("JT_ALICE", JT_LP_ROLE);
        JT_BOB = _generateProvider("JT_BOB", JT_LP_ROLE);
        JT_CHARLIE = _generateProvider("JT_CHARLIE", JT_LP_ROLE);
        JT_DAN = _generateProvider("JT_DAN", JT_LP_ROLE);

        JT_ALICE_ADDRESS = JT_ALICE.addr;
        JT_BOB_ADDRESS = JT_BOB.addr;
        JT_CHARLIE_ADDRESS = JT_CHARLIE.addr;
        JT_DAN_ADDRESS = JT_DAN.addr;

        // All unique provider addresses
        providers.push(ST_ALICE_ADDRESS);
        providers.push(JT_ALICE_ADDRESS);
        providers.push(ST_BOB_ADDRESS);
        providers.push(JT_BOB_ADDRESS);
        providers.push(ST_CHARLIE_ADDRESS);
        providers.push(JT_CHARLIE_ADDRESS);
        providers.push(ST_DAN_ADDRESS);
        providers.push(JT_DAN_ADDRESS);
    }

    function _setDeployedMarket(DeployScript.DeploymentResult memory _deploymentResult) internal {
        YDM = _deploymentResult.ydm;
        vm.label(address(YDM), "YDM");

        ST = _deploymentResult.seniorTranche;
        vm.label(address(ST), "ST");

        JT = _deploymentResult.juniorTranche;
        vm.label(address(JT), "JT");

        ACCOUNTANT = _deploymentResult.accountant;
        vm.label(address(ACCOUNTANT), "Accountant");

        KERNEL = _deploymentResult.kernel;
        vm.label(address(KERNEL), "Kernel");

        BLACKLIST = IRoycoBlacklist(_deploymentResult.roycoBlacklist);
        vm.label(address(BLACKLIST), "Blacklist");

        FACTORY = _deploymentResult.factory;
        vm.label(address(FACTORY), "Factory");

        ACCESS_MANAGER = _deploymentResult.accessManager;
        vm.label(address(ACCESS_MANAGER), "AccessManager");

        _wireExtraRoles();
    }

    /// @dev Wires roles that live in `ExtraRoles` and are intentionally NOT passed through
    ///      `factory.initialize` (canonical `RolesConfiguration.getRoleConfig` doesn't know
    ///      them, so including them in the init array would revert). Pranks FNDN (the
    ///      admin-role holder): `OWNER_ADDRESS` for a fresh in-memory deploy, `ROOT_MULTISIG`
    ///      when the test forks a chain where the factory is already on-chain.
    function _wireExtraRoles() internal {
        address fndn;
        (bool ownerIsAdmin,) = ACCESS_MANAGER.hasRole(0, OWNER_ADDRESS);
        if (ownerIsAdmin) {
            fndn = OWNER_ADDRESS;
        } else {
            // Live-chain factory admin: the production root multisig that holds the AccessManager admin role
            // (role id 0) on already-deployed factories, pinned as ROOT_MULTISIG in
            // script/config/MarketDeploymentConfig.sol. Hardcoded here (rather than imported) because that
            // config is script-side deploy tooling this test base intentionally does not depend on — if the
            // production admin ever rotates, fork tests hitting a live factory fail loudly on the grant below
            fndn = 0x7c405bbD131e42af506d14e752f2e59B19D49997;
        }

        // Standard 24h delay matches the canonical UNPAUSER config (and what `ApplySecurityMigration`
        // applies in production). The `_scheduleAndExecuteUnpause` test helper relies on a non-zero
        // delay — OZ AccessManager.schedule reverts when the caller's `setback == 0`.
        (bool unpauserHasRole,) = ACCESS_MANAGER.hasRole(ADMIN_UNPAUSER_ROLE, UNPAUSER_ADDRESS);
        if (!unpauserHasRole) {
            vm.prank(fndn);
            ACCESS_MANAGER.grantRole(ADMIN_UNPAUSER_ROLE, UNPAUSER_ADDRESS, 1 days);
        }
    }

    function _initWallet(string memory _name, uint256 _amount) internal returns (Vm.Wallet memory) {
        Vm.Wallet memory wallet = vm.createWallet(_name);
        vm.label(wallet.addr, _name);
        vm.deal(wallet.addr, _amount);
        return wallet;
    }

    /// @notice Generates a provider address
    /// @param _name The name of the provider
    /// @return provider The provider address
    function _generateProvider(string memory _name, uint64 _role) internal virtual returns (Vm.Wallet memory provider) {
        provider = _initWallet(_name, 10_000_000e6);

        vm.prank(LP_ROLE_ADMIN_ADDRESS);
        ACCESS_MANAGER.grantRole(_role, provider.addr, 0);

        return provider;
    }

    /// @notice Generates a provider address with both ST and JT LP roles
    /// @param index The index of the provider
    /// @return provider The provider address
    function _generateProvider(uint256 index) internal virtual returns (Vm.Wallet memory provider) {
        string memory providerName = string(abi.encodePacked("PROVIDER", vm.toString(index)));
        provider = _initWallet(providerName, 10_000_000e6);

        vm.startPrank(LP_ROLE_ADMIN_ADDRESS);
        ACCESS_MANAGER.grantRole(ST_LP_ROLE, provider.addr, 0);
        ACCESS_MANAGER.grantRole(JT_LP_ROLE, provider.addr, 0);
        vm.stopPrank();

        return provider;
    }

    /// @notice Converts the specified assets denominated in JT's tranche units to the kernel's NAV units
    /// @param _assets The assets denominated in JT's tranche units to convert to the kernel's NAV units
    /// @return value The specified assets denominated in JT's tranche units converted to the kernel's NAV units
    function _toJTValue(TRANCHE_UNIT _assets) internal view returns (NAV_UNIT) {
        return KERNEL.jtConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @notice Converts the specified assets denominated in ST's tranche units to the kernel's NAV units
    /// @param _assets The assets denominated in ST's tranche units to convert to the kernel's NAV units
    /// @return value The specified assets denominated in ST's tranche units converted to the kernel's NAV units
    function _toSTValue(TRANCHE_UNIT _assets) internal view returns (NAV_UNIT) {
        return KERNEL.stConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @notice Deploys a KERNEL using ERC1967 proxy
    /// @param _kernelImplementation The implementation address
    /// @param _kernelInitData The initialization data
    /// @return KERNELProxy The deployed proxy address
    function _deployKernel(address _kernelImplementation, bytes memory _kernelInitData) internal returns (address KERNELProxy) {
        KERNELProxy = address(new ERC1967Proxy(_kernelImplementation, _kernelInitData));
    }

    /// @notice Returns the fork configuration
    /// @return forkBlock The fork block
    /// @return forkRpcUrl The fork RPC URL
    function _forkConfiguration() internal virtual returns (uint256 forkBlock, string memory forkRpcUrl) {
        return (0, "");
    }

    /// @notice Generates role assignments using the role-specific addresses
    /// @return roleAssignments Array of role assignment configurations
    function _generateRoleAssignments() internal view returns (DeployScript.RoleAssignment[] memory roleAssignments) {
        return DEPLOY_SCRIPT.generateRolesAssignments(
            DeployScript.RoleAssignmentAddresses({
                pauserAddress: PAUSER_ADDRESS,
                unpauserAddress: UNPAUSER_ADDRESS,
                upgraderAddress: UPGRADER_ADDRESS,
                syncRoleAddress: SYNC_ROLE_ADDRESS,
                adminKernelAddress: KERNEL_ADMIN_ADDRESS,
                adminAccountantAddress: ACCOUNTANT_ADMIN_ADDRESS,
                adminProtocolFeeSetterAddress: PROTOCOL_FEE_SETTER_ADDRESS,
                adminOracleQuoterAddress: ORACLE_QUOTER_ADMIN_ADDRESS,
                lpRoleAdminAddress: LP_ROLE_ADMIN_ADDRESS,
                guardianAddress: ROLE_GUARDIAN_ADDRESS,
                deployerAddress: DEPLOYER_ADDRESS,
                deployerAdminAddress: DEPLOYER_ADMIN_ADDRESS,
                protocolFeeRecipientAddress: PROTOCOL_FEE_RECIPIENT_ADDRESS,
                balancerPoolManagerAddress: KERNEL_ADMIN_ADDRESS,
                marketOpsAddress: KERNEL_ADMIN_ADDRESS
            })
        );
    }

    // -----------------------------------------
    // Role-Specific Helper Functions
    // -----------------------------------------

    /// @notice Calls sync on the kernel with SYNC_ROLE
    function _sync() internal prankModifier(SYNC_ROLE_ADDRESS) {
        KERNEL.syncTrancheAccounting();
    }

    /// @notice Schedules and executes a kernel admin operation (handles delay)
    /// @param _target The target contract address
    /// @param _data The calldata for the operation
    function _executeKernelAdminOperation(address _target, bytes memory _data) internal {
        // Schedule the operation
        vm.prank(KERNEL_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(_target, _data, 0);

        // Warp past the delay (2 days for ADMIN_KERNEL_ROLE)
        vm.warp(block.timestamp + 2 days + 1);

        // Execute the operation
        vm.prank(KERNEL_ADMIN_ADDRESS);
        ACCESS_MANAGER.execute(_target, _data);
    }

    /// @notice Schedules and executes an accountant admin operation (handles delay)
    /// @param _target The target contract address
    /// @param _data The calldata for the operation
    function _executeAccountantAdminOperation(address _target, bytes memory _data) internal {
        // Schedule the operation
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(_target, _data, 0);

        // Warp past the delay (2 days for ADMIN_ACCOUNTANT_ROLE)
        vm.warp(block.timestamp + 2 days + 1);

        // Execute the operation
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        ACCESS_MANAGER.execute(_target, _data);
    }

    /// @notice Schedules and executes a protocol fee setter operation (handles delay)
    /// @param _target The target contract address
    /// @param _data The calldata for the operation
    function _executeProtocolFeeSetterOperation(address _target, bytes memory _data) internal {
        // Schedule the operation
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        ACCESS_MANAGER.schedule(_target, _data, 0);

        // Warp past the delay (2 days for ADMIN_PROTOCOL_FEE_SETTER_ROLE)
        vm.warp(block.timestamp + 2 days + 1);

        // Execute the operation
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        ACCESS_MANAGER.execute(_target, _data);
    }

    /// @notice Sets the protocol fee recipient via kernel admin (with scheduling)
    /// @param _newRecipient The new protocol fee recipient address
    function _setProtocolFeeRecipient(address _newRecipient) internal {
        bytes memory data = abi.encodeCall(KERNEL.setProtocolFeeRecipient, (_newRecipient));
        _executeKernelAdminOperation(address(KERNEL), data);
    }

}
