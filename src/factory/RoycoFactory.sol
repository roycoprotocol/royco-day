// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManagedUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Create2 } from "../../lib/openzeppelin-contracts/contracts/utils/Create2.sol";
import { IRoycoAccountant } from "../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoFactory } from "../../src/interfaces/IRoycoFactory.sol";
import { IRoycoKernel } from "../../src/interfaces/kernel/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/tranche/IRoycoVaultTranche.sol";
import { MarketDeploymentParams, RolesTargetConfiguration, RoycoMarket } from "../../src/libraries/Types.sol";
import { RolesConfiguration } from "./RolesConfiguration.sol";

/**
 * @title RoycoFactory
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Factory contract for deploying and initializing Royco markets (Senior Tranche, Junior Tranche, Kernel, and Accountant)
 * @notice The factory also acts as a singleton access manager for all the Royco markets and their constituent contracts
 * @dev The factory deploys each market's constituent contracts using the UUPS proxy pattern
 */
contract RoycoFactory is AccessManager, RolesConfiguration, IRoycoFactory {
    /// @dev Mapping from a senior tranche to its corresponding junior tranche
    mapping(address st => address jt) public seniorTrancheToJuniorTranche;

    /// @dev Mapping from a junior tranche to its corresponding senior tranche
    mapping(address jt => address st) public juniorTrancheToSeniorTranche;

    /**
     * @notice Initializes the Royco Factory
     * @param _admin The admin of the factory
     * @param _deployer The deployer address that can deploy new markets
     */
    constructor(address _admin, address _deployer) AccessManager(_admin) {
        // Grant the deployer the deployer role
        _grantRole(DEPLOYER_ROLE, _deployer, 0, 0);
        // Set the deployer role on the deployMarket function
        _setTargetFunctionRole(address(this), RoycoFactory.deployMarket.selector, DEPLOYER_ROLE);
    }

    /// @inheritdoc IRoycoFactory
    function deployMarket(MarketDeploymentParams calldata _params) external override(IRoycoFactory) onlyAuthorized returns (RoycoMarket memory roycoMarket) {
        // Validate the deployment parameters
        _validateDeploymentParams(_params);

        // Deploy the Royco market
        roycoMarket = _deployMarket(_params);

        // Validate the deployment
        _validateDeployment(roycoMarket);

        // Ensure that the accountant can sync the market state
        _grantRole(SYNC_ROLE, address(roycoMarket.accountant), 0, 0);

        // Configure the roles
        _configureRoles(roycoMarket, _params.roles);

        // Update the mappings between the two deployed tranches
        address seniorTranche = address(roycoMarket.seniorTranche);
        address juniorTranche = address(roycoMarket.juniorTranche);
        seniorTrancheToJuniorTranche[seniorTranche] = juniorTranche;
        juniorTrancheToSeniorTranche[juniorTranche] = seniorTranche;

        emit MarketDeployed(roycoMarket, _params);
    }

    /// @inheritdoc IRoycoFactory
    function predictERC1967ProxyAddress(address _implementation, bytes32 _salt) external view override(IRoycoFactory) returns (address proxy) {
        proxy = Create2.computeAddress(_salt, keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(_implementation, ""))));
    }

    /**
     * @notice Deploys the contracts for a new Royco market
     * @param _params The parameters for deploying a new Royco market
     * @param roycoMarket The deployed components constituting the Royco market
     */
    function _deployMarket(MarketDeploymentParams calldata _params) internal virtual returns (RoycoMarket memory roycoMarket) {
        // Deploy the tranches, kernel, and accountant for the market with empty initialization data
        // It is expected that the kernel initialization data contains the address of the accountant and vice versa
        // Therefore, it is expected that the proxy address is precomputed based on an uninitialized erc1967 proxy initcode
        // and that the proxy is initalized separately after deployment, in the same transaction

        // Deploy the senior tranche with empty initialization data
        roycoMarket.seniorTranche =
            IRoycoVaultTranche(_deployERC1967ProxyDeterministic(address(_params.seniorTrancheImplementation), _params.seniorTrancheProxyDeploymentSalt));

        // Deploy the junior tranche with empty initialization data
        roycoMarket.juniorTranche =
            IRoycoVaultTranche(_deployERC1967ProxyDeterministic(address(_params.juniorTrancheImplementation), _params.juniorTrancheProxyDeploymentSalt));

        // Deploy the kernel with empty initialization data
        roycoMarket.kernel = IRoycoKernel(_deployERC1967ProxyDeterministic(address(_params.kernelImplementation), _params.kernelProxyDeploymentSalt));

        // Deploy the accountant with empty initialization data
        roycoMarket.accountant =
            IRoycoAccountant(_deployERC1967ProxyDeterministic(address(_params.accountantImplementation), _params.accountantProxyDeploymentSalt));

        // Initialize the senior tranche
        (bool success, bytes memory data) = address(roycoMarket.seniorTranche).call(_params.seniorTrancheInitializationData);
        require(success, FAILED_TO_INITIALIZE_SENIOR_TRANCHE(data));

        // Initialize the junior tranche
        (success, data) = address(roycoMarket.juniorTranche).call(_params.juniorTrancheInitializationData);
        require(success, FAILED_TO_INITIALIZE_JUNIOR_TRANCHE(data));

        // Initialize the kernel
        (success, data) = address(roycoMarket.kernel).call(_params.kernelInitializationData);
        require(success, FAILED_TO_INITIALIZE_KERNEL(data));

        // Initialize the accountant
        (success, data) = address(roycoMarket.accountant).call(_params.accountantInitializationData);
        require(success, FAILED_TO_INITIALIZE_ACCOUNTANT(data));
    }

    /// @notice Validates the deployments
    /// @param _roycoMarket The deployed Royco market to validate
    function _validateDeployment(RoycoMarket memory _roycoMarket) internal view {
        // Check that the access manager is set on the contracts
        require(AccessManagedUpgradeable(address(_roycoMarket.accountant)).authority() == address(this), INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(address(_roycoMarket.kernel)).authority() == address(this), INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(address(_roycoMarket.seniorTranche)).authority() == address(this), INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(address(_roycoMarket.juniorTranche)).authority() == address(this), INVALID_ACCESS_MANAGER());

        // Check that the kernel is set on the tranches
        require(address(_roycoMarket.seniorTranche.kernel()) == address(_roycoMarket.kernel), INVALID_KERNEL_ON_SENIOR_TRANCHE());
        require(address(_roycoMarket.juniorTranche.kernel()) == address(_roycoMarket.kernel), INVALID_KERNEL_ON_JUNIOR_TRANCHE());

        // Check that the accountant is set on the kernel
        require(address(_roycoMarket.kernel.ACCOUNTANT()) == address(_roycoMarket.accountant), INVALID_ACCOUNTANT_ON_KERNEL());

        // Check that the kernel is set on the accountant
        require(address(_roycoMarket.accountant.getState().kernel) == address(_roycoMarket.kernel), INVALID_KERNEL_ON_ACCOUNTANT());
    }

    /// @notice Validates the deployment parameters
    /// @param _params The parameters to validate
    function _validateDeploymentParams(MarketDeploymentParams calldata _params) internal pure {
        require(bytes(_params.seniorTrancheName).length > 0, INVALID_NAME());
        require(bytes(_params.seniorTrancheSymbol).length > 0, INVALID_SYMBOL());
        require(bytes(_params.juniorTrancheName).length > 0, INVALID_NAME());
        require(bytes(_params.juniorTrancheSymbol).length > 0, INVALID_SYMBOL());
        require(_params.marketId != bytes32(0), INVALID_MARKET_ID());
        // Validate the implementation addresses
        require(address(_params.kernelImplementation) != address(0), INVALID_KERNEL_IMPLEMENTATION());
        require(address(_params.accountantImplementation) != address(0), INVALID_ACCOUNTANT_IMPLEMENTATION());
        require(address(_params.seniorTrancheImplementation) != address(0), INVALID_SENIOR_TRANCHE_IMPLEMENTATION());
        require(address(_params.juniorTrancheImplementation) != address(0), INVALID_JUNIOR_TRANCHE_IMPLEMENTATION());
        // Validate the initialization data
        require(_params.kernelInitializationData.length > 0, INVALID_KERNEL_INITIALIZATION_DATA());
        require(_params.accountantInitializationData.length > 0, INVALID_ACCOUNTANT_INITIALIZATION_DATA());
        // Validate the deployment salts
        require(_params.seniorTrancheProxyDeploymentSalt != bytes32(0), INVALID_SENIOR_TRANCHE_PROXY_DEPLOYMENT_SALT());
        require(_params.juniorTrancheProxyDeploymentSalt != bytes32(0), INVALID_JUNIOR_TRANCHE_PROXY_DEPLOYMENT_SALT());
        require(_params.kernelProxyDeploymentSalt != bytes32(0), INVALID_KERNEL_PROXY_DEPLOYMENT_SALT());
        require(_params.accountantProxyDeploymentSalt != bytes32(0), INVALID_ACCOUNTANT_PROXY_DEPLOYMENT_SALT());
    }

    /**
     * @notice Configures the roles for the deployed contracts
     * @param _roycoMarket The deployed contracts to configure
     * @param _roles The roles to configure
     */
    function _configureRoles(RoycoMarket memory _roycoMarket, RolesTargetConfiguration[] calldata _roles) internal {
        for (uint256 i = 0; i < _roles.length; ++i) {
            RolesTargetConfiguration calldata role = _roles[i];

            // Validate that the selectors and roles length match
            require(role.selectors.length == role.roles.length, ROLES_CONFIGURATION_LENGTH_MISMATCH());

            // Validate that the target is one of the deployed contracts
            address target = role.target;
            require(
                target == address(_roycoMarket.accountant) || target == address(_roycoMarket.kernel) || target == address(_roycoMarket.seniorTranche)
                    || target == address(_roycoMarket.juniorTranche),
                INVALID_TARGET(target)
            );

            for (uint256 j = 0; j < role.selectors.length; ++j) {
                _setTargetFunctionRole(target, role.selectors[j], role.roles[j]);
            }
        }
    }

    /**
     * @notice Deploys a tranche using ERC1967 proxy deterministically
     * @param _implementation The implementation address
     * @param _salt The salt for the deployment
     *  @return proxy The deployed proxy address
     */
    function _deployERC1967ProxyDeterministic(address _implementation, bytes32 _salt) internal returns (address proxy) {
        proxy = Create2.deploy(0, _salt, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(_implementation, "")));
    }
}
