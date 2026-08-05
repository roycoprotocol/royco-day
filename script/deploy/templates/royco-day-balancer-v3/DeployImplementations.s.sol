// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ConstantPriceFeed } from "../../../../lib/balancer-v3-monorepo/pkg/oracles/contracts/ConstantPriceFeed.sol";
import { GyroECLPPoolFactory } from "../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { AccessManager } from "../../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { UpgradeableBeacon } from "../../../../lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { RoycoDayAccountant } from "../../../../src/accountant/RoycoDayAccountant.sol";
import { ADMIN_UPGRADER_ROLE } from "../../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../../src/factory/RoycoAccessManager.sol";
import { IRoycoAccessManager } from "../../../../src/interfaces/factory/IRoycoAccessManager.sol";
import { RoycoDayBalancerV3Kernel } from "../../../../src/kernels/RoycoDayBalancerV3Kernel.sol";
import { RoycoJuniorTranche } from "../../../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoLiquidityProviderTranche } from "../../../../src/tranches/RoycoLiquidityProviderTranche.sol";
import { RoycoSeniorTranche } from "../../../../src/tranches/RoycoSeniorTranche.sol";
import { ImplementationSet } from "../../../config/DeploymentTypes.sol";
import { TemplateConfig } from "../../config/TemplateConfig.sol";
import { DeployScriptBase } from "../../core/DeployScriptBase.sol";
import { RoycoDeterministic } from "../../utils/RoycoDeterministic.sol";

/**
 * @title DeployImplementationsComponent
 * @notice Deploys (or reuses) the Day family's chain-wide implementation set: five component implementations, the
 *         UpgradeableBeacon in front of each, and the BPT oracle's constant-1.0 price feed — then binds every
 *         beacon's `upgradeTo` to ADMIN_UPGRADER_ROLE (skipping any already configured).
 * @dev Every artifact is market-independent, so CREATE2 makes the whole phase idempotent: a second market on the
 *      same chain redeploys nothing. The beacon addresses are stable across implementation upgrades, which is what
 *      keeps the template address stable. The kernel implementation's only construction input is the chain's
 *      Balancer Vault (from this family's TemplateConfig venue mapping).
 */
contract DeployImplementationsComponent is DeployScriptBase, TemplateConfig {
    address internal ACCESS_MANAGER;

    constructor(bool _isTestEnv, address _accessManager) {
        isTestEnv = _isTestEnv;
        ACCESS_MANAGER = _accessManager;
    }

    /// @notice Deploys the implementation set under its own broadcast, then binds the beacon upgrade roles
    function execute(uint256 _deployerPrivateKey) public returns (ImplementationSet memory impls) {
        vm.startBroadcast(_deployerPrivateKey);
        impls = deployImplementationSet();
        bindBeaconUpgradeRoles(impls);
        vm.stopBroadcast();
    }

    /// @notice Deploys (or reuses) the implementation set WITHOUT role bindings, inside the caller's context
    /// @dev The seam tests and the orchestrator compose against; bindings need admin and broadcast separately
    function deployImplementationSet() public returns (ImplementationSet memory impls) {
        _logSection("Chain-wide implementations, beacons, and yield distribution models");
        address authority = ACCESS_MANAGER;

        impls.seniorTrancheBeacon = _deployBeacon("SeniorTranche", _singletonSalt("ROYCO_SENIOR_TRANCHE"), type(RoycoSeniorTranche).creationCode, authority);
        impls.juniorTrancheBeacon = _deployBeacon("JuniorTranche", _singletonSalt("ROYCO_JUNIOR_TRANCHE"), type(RoycoJuniorTranche).creationCode, authority);
        impls.liquidityProviderTrancheBeacon =
            _deployBeacon("LPTranche    ", _singletonSalt("ROYCO_LIQUIDITY_PROVIDER_TRANCHE"), type(RoycoLiquidityProviderTranche).creationCode, authority);
        impls.accountantBeacon = _deployBeacon("Accountant   ", _singletonSalt("ROYCO_ACCOUNTANT"), type(RoycoDayAccountant).creationCode, authority);

        // The kernel implementation's only construction input is the chain's Balancer Vault, which is not market-specific
        (address gyroFactory,) = venueFactories(block.chainid);
        impls.kernelBeacon = _deployBeacon(
            "Kernel       ",
            _singletonSalt("ROYCO_DAY_BALANCER_V3_KERNEL"),
            abi.encodePacked(type(RoycoDayBalancerV3Kernel).creationCode, abi.encode(GyroECLPPoolFactory(gyroFactory).getVault())),
            authority
        );

        bool existed;
        (impls.bptOracleConstantPriceFeed, existed) =
            deployWithSanityChecks(_singletonSalt("ROYCO_BPT_ORACLE_CONSTANT_PRICE_FEED"), type(ConstantPriceFeed).creationCode, false);
        _logDeploy("ConstantPriceFeed     ", impls.bptOracleConstantPriceFeed, existed);
    }

    /**
     * @notice Deploys (or reuses) one component's implementation and the beacon that points at it
     * @dev Both are CREATE2-deployed at derived singleton salts, so the whole phase is idempotent across re-runs. The
     *      beacon's address is stable across implementation upgrades, which is what keeps the template address stable
     */
    function _deployBeacon(
        string memory _label,
        bytes32 _baseSalt,
        bytes memory _implementationCreationCode,
        address _authority
    )
        internal
        returns (address beacon)
    {
        (address implementation, bool implementationExisted) =
            deployWithSanityChecks(keccak256(abi.encodePacked(_baseSalt, "_IMPLEMENTATION")), _implementationCreationCode, false);
        _logDeploy(string.concat(_label, " (impl)  "), implementation, implementationExisted);

        bool beaconExisted;
        (beacon, beaconExisted) = deployWithSanityChecks(
            keccak256(abi.encodePacked(_baseSalt, "_BEACON")),
            abi.encodePacked(type(UpgradeableBeacon).creationCode, abi.encode(implementation, _authority)),
            false
        );
        _logDeploy(string.concat(_label, " (beacon)"), beacon, beaconExisted);
    }

    /// @notice Binds `upgradeTo` on every component beacon to ADMIN_UPGRADER_ROLE, skipping any already configured
    /// @dev A beacon governs every market of its type, so this is wired once per chain; the access manager records
    ///      every configured target and the gatekeeper rejects reconfiguring one
    function bindBeaconUpgradeRoles(ImplementationSet memory _impls) public {
        address[5] memory beacons =
            [_impls.seniorTrancheBeacon, _impls.juniorTrancheBeacon, _impls.liquidityProviderTrancheBeacon, _impls.kernelBeacon, _impls.accountantBeacon];
        bytes4[] memory selectors = _sel(UpgradeableBeacon.upgradeTo.selector);
        for (uint256 i; i < beacons.length; ++i) {
            if (IRoycoAccessManager(ACCESS_MANAGER).wasEverConfigured(beacons[i])) continue;
            AccessManager(ACCESS_MANAGER).setTargetFunctionRole(beacons[i], selectors, ADMIN_UPGRADER_ROLE);
        }
    }
}

/// @notice CLI entrypoint: deploys against the predicted AccessManager for the env's deployer
contract DeployImplementations is DeployImplementationsComponent {
    constructor() DeployImplementationsComponent(vm.envOr("IS_TEST_DEPLOYMENT", false), _predictAccessManager()) { }

    function _predictAccessManager() internal view returns (address) {
        bool isTest = vm.envOr("IS_TEST_DEPLOYMENT", false);
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        return RoycoDeterministic.create2Address(
            RoycoDeterministic.singletonSalt("ROYCO_ACCESS_MANAGER", isTest),
            keccak256(abi.encodePacked(type(RoycoAccessManager).creationCode, abi.encode(deployer)))
        );
    }

    function run() external {
        enableLogging();
        execute(vm.envUint("DEPLOYER_PRIVATE_KEY"));
    }
}
