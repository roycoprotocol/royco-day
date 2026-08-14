// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TemplatePolicy } from "../../config/DeploymentTypes.sol";
import { EnvConfig } from "./EnvConfig.sol";

/**
 * @title TemplateConfig
 * @notice The template deployment's own configuration: the SYSTEM policy the template is constructed with (protocol
 *         fees, fee recipient, and pool yield-fee flags) plus the per-chain Balancer venue factories.
 * @dev The policy is template construction state — no market deployer chooses it — and the template's CREATE2 salt
 *      hashes it, so changing any field here moves the template address (a deliberate redeploy).
 */
abstract contract TemplateConfig is EnvConfig {
    /// @dev The per-chain Balancer V3 venue factories the template family is constructed against
    mapping(uint256 chainId => address) internal GYRO_ECLP_POOL_FACTORY;
    mapping(uint256 chainId => address) internal ECLP_LP_ORACLE_FACTORY;

    /// @dev When set, `templatePolicy` returns this instead of the canonical values. Test-only: fork fixtures pin the
    ///      fee policy their reference math assumes without editing the production config
    bool internal templatePolicyOverridden;
    TemplatePolicy internal templatePolicyOverride;

    constructor() {
        // https://docs.balancer.fi/developer-reference/contracts/deployment-addresses/mainnet.html
        GYRO_ECLP_POOL_FACTORY[1] = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;
        ECLP_LP_ORACLE_FACTORY[1] = 0x301EDe5Fd4f9d7266B09c3A2E38F97776447154B;

        // https://docs.balancer.fi/developer-reference/contracts/deployment-addresses/arbitrum.html
        GYRO_ECLP_POOL_FACTORY[42_161] = 0xe31715e75207acC8bfadd96902FF522058928479;
        ECLP_LP_ORACLE_FACTORY[42_161] = 0xD9E91f7aD501929b089992842a3f193795E6479e;

        // https://docs.balancer.fi/developer-reference/contracts/deployment-addresses/base.html
        GYRO_ECLP_POOL_FACTORY[8453] = 0x86a0E97eC0D5dB8DAE106D3067358d41968fD12c;
        ECLP_LP_ORACLE_FACTORY[8453] = 0x2cf8e145Bdfe7c52b49AD9bB3c294a31B2736c59;
    }

    /// @notice The Balancer venue factories the template is constructed against on `_chainId`
    function venueFactories(uint256 _chainId) public view returns (address gyroECLPPoolFactory, address eclpLPOracleFactory) {
        return (GYRO_ECLP_POOL_FACTORY[_chainId], ECLP_LP_ORACLE_FACTORY[_chainId]);
    }

    /// @notice The SYSTEM policy the template is constructed with for the environment
    function templatePolicy(bool _isTest) public view returns (TemplatePolicy memory) {
        if (templatePolicyOverridden) return templatePolicyOverride;
        return TemplatePolicy({
            protocolFeeRecipient: _isTest ? testDeploymentAdmin : PROTOCOL_FEE_RECIPIENT,
            stProtocolFeeWAD: 0,
            jtProtocolFeeWAD: 0,
            jtYieldShareProtocolFeeWAD: 0.45e18, // 45%
            lptYieldShareProtocolFeeWAD: 0.45e18, // 45%
            chargeYieldFeeOnSeniorTrancheShares: false,
            chargeYieldFeeOnQuoteAsset: false
        });
    }

    /// @notice Overrides the template policy, for tests that need a pinned fee set
    function overrideTemplatePolicyForTest(TemplatePolicy memory _policy) public {
        templatePolicyOverridden = true;
        templatePolicyOverride = _policy;
    }
}
