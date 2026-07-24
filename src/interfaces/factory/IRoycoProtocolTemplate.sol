// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

/**
 * @title IRoycoProtocolTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Interface every Royco market deployment template implements
 */
interface IRoycoProtocolTemplate {
    /**
     * @notice The set of contracts produced by a market deployment
     * @custom:field seniorTranche - The senior tranche proxy
     * @custom:field juniorTranche - The junior tranche proxy
     * @custom:field liquidityProviderTranche - The liquidity provider tranche proxy (Royco Day markets only, zero otherwise)
     * @custom:field kernel - The kernel proxy
     * @custom:field accountant - The accountant proxy
     * @custom:field ydm - The junior tranche's (possibly shared) YDM singleton
     * @custom:field lptYdm - The liquidity provider tranche's (possibly shared) LDM singleton (zero for markets without a liquidity provider tranche)
     * @custom:field extras - ABI-encoded template-specific addenda consumed by downstream tooling
     */
    struct DeploymentResult {
        address seniorTranche;
        address juniorTranche;
        address liquidityProviderTranche;
        address kernel;
        address accountant;
        address ydm;
        address lptYdm;
        bytes extras;
    }

    /**
     * @notice Deploys a market from an ABI-encoded params blob, only callable by the factory
     * @param _params The ABI-encoded template-specific params
     * @return result The deployed market's contracts
     */
    function deployMarket(bytes calldata _params) external returns (DeploymentResult memory result);

    /**
     * @notice Performs post-deployment configuration, typically of the market's periphery (entry point tranche configs, syncer kernel registration)
     * @param _result The market's deployment result, as returned by `deployMarket`
     * @param _params The same ABI-encoded template-specific params passed to `deployMarket`
     */
    function postMarketRegistration(DeploymentResult calldata _result, bytes calldata _params) external;
}
