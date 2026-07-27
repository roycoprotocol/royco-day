// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { CREATE3 } from "../../lib/solady/src/utils/CREATE3.sol";

/**
 * @title RoycoCreate3Deployer
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice A minimal CREATE3 deployer, itself deployed deterministically via CREATE2, so the addresses it hands out
 *         depend on a salt alone and NOT on the deployed contract's creation code
 */
contract RoycoCreate3Deployer {
    /// @notice Emitted when a contract is deployed
    event Deployed(address indexed deployed, address indexed deployer, bytes32 salt);

    /**
     * @notice Deploys `_creationCode` at the CREATE3 address this deployer resolves for `msg.sender` and `_salt`
     * @param _salt The caller's salt, namespaced to the caller before use
     * @param _creationCode The full creation code, constructor arguments included
     * @return deployed The deployed contract
     */
    function deploy(bytes32 _salt, bytes calldata _creationCode) external payable returns (address deployed) {
        deployed = CREATE3.deployDeterministic(msg.value, _creationCode, _namespacedSalt(msg.sender, _salt));
        emit Deployed(deployed, msg.sender, _salt);
    }

    /**
     * @notice The address `deploy` resolves for a given deployer and salt, independent of what will be deployed there
     * @param _deployer The address that will call `deploy`
     * @param _salt The salt it will pass
     * @return deployed The address the deployment will occupy
     */
    function predict(address _deployer, bytes32 _salt) external view returns (address deployed) {
        return CREATE3.predictDeterministicAddress(_namespacedSalt(_deployer, _salt), address(this));
    }

    /// @dev Binds a salt to its caller, so one deployer's salt space can never collide with or be front-run by another's
    function _namespacedSalt(address _deployer, bytes32 _salt) private pure returns (bytes32) {
        return keccak256(abi.encode(_deployer, _salt));
    }
}
