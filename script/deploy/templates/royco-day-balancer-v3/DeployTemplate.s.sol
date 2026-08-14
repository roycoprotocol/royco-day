// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ILPOracleFactoryBase } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { GyroECLPPoolFactory } from "../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { AccessManager } from "../../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ADMIN_FACTORY_ROLE, ADMIN_PROTOCOL_FEE_SETTER_ROLE } from "../../../../src/factory/Roles.sol";
import { RoycoFactory } from "../../../../src/factory/RoycoFactory.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { BaseDeploymentTemplate } from "../../../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { IRoycoAccessManager } from "../../../../src/interfaces/factory/IRoycoAccessManager.sol";
import { IRoycoFactory } from "../../../../src/interfaces/factory/IRoycoFactory.sol";
import { ImplementationSet, TemplatePolicy, TemplateUpstream } from "../../../config/DeploymentTypes.sol";
import { TemplateConfig } from "../../config/TemplateConfig.sol";
import { DeployScriptBase } from "../../core/DeployScriptBase.sol";

/**
 * @title DeployTemplateComponent
 * @notice Deploys (or reuses) the Day family's deployment template — pinned to the chain's implementation set, the
 *         shared blacklist, the Balancer venue factories, and the SYSTEM policy — registers it on the factory, and
 *         binds its configuration surface to the governing roles.
 * @dev CREATE2-deployed at a salt derived from the FULL construction params, so a chain reaches the same template
 *      for the same wiring and a genuinely different wiring gets its own template rather than silently reusing one.
 *      The yield distribution models are NOT construction params: they live in the template's own storage and are
 *      registered separately (DeployYDMs), so shipping a new model shape does not move the template address.
 * @dev Registration and role binding require the deployer's ADMIN_FACTORY_ROLE / ADMIN_ROLE — this script must run
 *      BEFORE the renounce step.
 */
contract DeployTemplateComponent is DeployScriptBase, TemplateConfig {
    TemplateUpstream internal UP;

    constructor(bool _isTestEnv, TemplateUpstream memory _up) {
        isTestEnv = _isTestEnv;
        UP = _up;
    }

    /// @notice Deploys, registers, and role-binds the template under its own broadcast
    function execute(uint256 _deployerPrivateKey) public returns (address template) {
        vm.startBroadcast(_deployerPrivateKey);
        template = _execute();
        vm.stopBroadcast();
    }

    function _execute() internal returns (address template) {
        bool existed;
        (template, existed) = deployTemplate();
        if (!RoycoFactory(UP.factory).isTemplateEnabled(template)) RoycoFactory(UP.factory).registerTemplate(template);
        _logDeploy("Template           ", template, existed);
        _bindTemplateConfigurationRoles(template);
    }

    /**
     * @notice Deploys (or reuses) the template pinned to the upstream implementation set and this config's policy
     * @dev The construction-params assembly is ADDRESS-CRITICAL: the CREATE2 salt hashes the encoded struct, so any
     *      field reorder or value change moves the template (and with it every market's mined id validity)
     */
    function deployTemplate() public returns (address template, bool existed) {
        (address gyroFactory, address eclpOracleFactory) = venueFactories(block.chainid);
        TemplatePolicy memory policy = templatePolicy(isTestEnv);

        RoycoDayBalancerV3MarketDeploymentTemplate.TemplateConstructionParams memory cp;
        cp.seniorTrancheBeacon = UP.impls.seniorTrancheBeacon;
        cp.juniorTrancheBeacon = UP.impls.juniorTrancheBeacon;
        cp.liquidityProviderTrancheBeacon = UP.impls.liquidityProviderTrancheBeacon;
        cp.accountantBeacon = UP.impls.accountantBeacon;
        cp.kernelBeacon = UP.impls.kernelBeacon;
        cp.bptOracleConstantPriceFeed = UP.impls.bptOracleConstantPriceFeed;
        cp.factory = IRoycoFactory(UP.factory);
        cp.balancerV3PoolFactory = GyroECLPPoolFactory(gyroFactory);
        cp.eclpLPOracleFactory = ILPOracleFactoryBase(eclpOracleFactory);

        cp.protocolFeeRecipient = policy.protocolFeeRecipient;
        cp.protocolFeeConfig = BaseDeploymentTemplate.ProtocolFeeConfig({
            stProtocolFeeWAD: policy.stProtocolFeeWAD,
            jtProtocolFeeWAD: policy.jtProtocolFeeWAD,
            jtYieldShareProtocolFeeWAD: policy.jtYieldShareProtocolFeeWAD,
            lptYieldShareProtocolFeeWAD: policy.lptYieldShareProtocolFeeWAD
        });
        cp.balancerPoolYieldFeeConfig = RoycoDayBalancerV3MarketDeploymentTemplate.BalancerPoolYieldFeeConfig({
            chargeYieldFeeOnSeniorTrancheShares: policy.chargeYieldFeeOnSeniorTrancheShares,
            chargeYieldFeeOnQuoteAsset: policy.chargeYieldFeeOnQuoteAsset
        });

        (template, existed) = deployWithSanityChecks(
            _singletonSalt(string.concat("ROYCO_DAY_BALANCER_V3_TEMPLATE_", vm.toString(keccak256(abi.encode(cp))))),
            abi.encodePacked(type(RoycoDayBalancerV3MarketDeploymentTemplate).creationCode, abi.encode(cp)),
            false
        );
    }

    /**
     * @notice Binds every selector on the template's configuration surface to the role that governs it
     * @dev Skips a template the access manager has ever configured (the gatekeeper rejects reconfiguration)
     */
    function _bindTemplateConfigurationRoles(address _template) internal {
        if (IRoycoAccessManager(UP.accessManager).wasEverConfigured(_template)) return;

        bytes4[] memory factoryAdminSelectors = new bytes4[](3);
        factoryAdminSelectors[0] = BaseDeploymentTemplate.setYieldDistributionModels.selector;
        factoryAdminSelectors[1] = BaseDeploymentTemplate.setProtocolFeeRecipient.selector;
        factoryAdminSelectors[2] = RoycoDayBalancerV3MarketDeploymentTemplate.setBalancerPoolYieldFeeConfig.selector;
        AccessManager(UP.accessManager).setTargetFunctionRole(_template, factoryAdminSelectors, ADMIN_FACTORY_ROLE);

        // The fee set answers to the same role as each market's own protocol fee setters
        AccessManager(UP.accessManager)
            .setTargetFunctionRole(_template, _sel(BaseDeploymentTemplate.setProtocolFeeConfig.selector), ADMIN_PROTOCOL_FEE_SETTER_ROLE);
    }
}
