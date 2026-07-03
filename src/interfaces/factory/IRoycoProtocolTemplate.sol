// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IRoycoProtocolTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Interface every Royco market deployment template implements. The factory drives a template through
 *         `initialize` (once, at registration), then `deployMarket` + `verify` inside an `executeMarketDeployment` window.
 */
interface IRoycoProtocolTemplate {
    /**
     * @notice The set of contracts produced by a market deployment.
     * @custom:field seniorTranche - The senior tranche proxy.
     * @custom:field juniorTranche - The junior tranche proxy.
     * @custom:field liquidityTranche - The liquidity tranche proxy (Royco Day markets only; zero otherwise).
     * @custom:field kernel - The kernel proxy.
     * @custom:field accountant - The accountant proxy.
     * @custom:field ydm - The (possibly shared) YDM singleton.
     * @custom:field extras - ABI-encoded template-specific addenda consumed by `verify` and downstream tooling.
     */
    struct DeploymentResult {
        address seniorTranche;
        address juniorTranche;
        address liquidityTranche;
        address kernel;
        address accountant;
        address ydm;
        bytes extras;
    }

    /// @notice Thrown when the supplied deployment params fail template-specific validation.
    error INVALID_PARAMS();

    /**
     * @notice Loads the template's SSTORE2-backed component creation codes. Called once by the factory at registration.
     * @param _componentIds The component IDs to populate.
     * @param _creationCodes The creation code for each component, index-aligned with `_componentIds`.
     */
    function initialize(bytes32[] calldata _componentIds, bytes[] calldata _creationCodes) external;

    /// @notice Validates an ABI-encoded params blob without deploying.
    /// @param _params The ABI-encoded template-specific params.
    function validateParams(bytes calldata _params) external view;

    /**
     * @notice Deploys a market from an ABI-encoded params blob. Only callable by the factory.
     * @param _params The ABI-encoded template-specific params.
     * @return result The deployed market's contracts.
     */
    function deployMarket(bytes calldata _params) external returns (DeploymentResult memory result);

    /// @notice Verifies the cross-wiring of a deployed market. Reverts on any mismatch.
    /// @param _result The deployment result to verify.
    function verify(DeploymentResult calldata _result) external view;
}
