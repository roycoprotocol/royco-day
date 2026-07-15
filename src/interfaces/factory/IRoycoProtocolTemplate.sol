// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IRoycoProtocolTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Interface every Royco market deployment template implements
 *         The deployer initializes the template once
 *         (loading its component creation codes) before registering it with the factory, and the factory then drives it
 *         through `deployMarket` inside an `executeMarketDeployment` window
 */
interface IRoycoProtocolTemplate {
    /**
     * @notice The set of contracts produced by a market deployment
     * @custom:field seniorTranche - The senior tranche proxy
     * @custom:field juniorTranche - The junior tranche proxy
     * @custom:field liquidityTranche - The liquidity tranche proxy (Royco Day markets only, zero otherwise)
     * @custom:field kernel - The kernel proxy
     * @custom:field accountant - The accountant proxy
     * @custom:field ydm - The junior tranche's (possibly shared) YDM singleton
     * @custom:field ltYdm - The liquidity tranche's (possibly shared) LDM singleton (zero for markets without a liquidity tranche)
     * @custom:field extras - ABI-encoded template-specific addenda consumed by downstream tooling
     */
    struct DeploymentResult {
        address seniorTranche;
        address juniorTranche;
        address liquidityTranche;
        address kernel;
        address accountant;
        address ydm;
        address ltYdm;
        bytes extras;
    }

    /// @notice Thrown when the supplied deployment params fail template-specific validation
    error INVALID_PARAMS();

    /**
     * @notice Loads the template's SSTORE2-backed component creation codes, called once by the deployer before the
     *         template is registered with the factory
     * @param _componentIds The component IDs to populate
     * @param _creationCodes The creation code for each component, index-aligned with `_componentIds`
     */
    function initialize(bytes32[] calldata _componentIds, bytes[] calldata _creationCodes) external;

    /**
     * @notice Deploys a market from an ABI-encoded params blob, only callable by the factory
     * @param _params The ABI-encoded template-specific params
     * @return result The deployed market's contracts
     */
    function deployMarket(bytes calldata _params) external returns (DeploymentResult memory result);
}
