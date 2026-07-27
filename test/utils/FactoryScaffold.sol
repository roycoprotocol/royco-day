// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { RoycoAccessManager } from "../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { RoycoCreate3Deployer } from "../../src/factory/RoycoCreate3Deployer.sol";
import { RoycoFactoryGatekeeper } from "../../src/factory/RoycoFactoryGatekeeper.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_FACTORY_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    BURNER_ROLE,
    DEPLOYER_ROLE,
    MARKET_ROLE_GRANTOR_ROLE,
    SYNC_ROLE
} from "../../src/factory/Roles.sol";
import { IRoycoAuth } from "../../src/interfaces/IRoycoAuth.sol";
import { IRoycoFactory } from "../../src/interfaces/factory/IRoycoFactory.sol";

/**
 * @title FactoryScaffold
 * @notice Stands up the access manager / gatekeeper / factory triangle the way `Deploy.s.sol` does, for the hand-rolled
 *         fixtures that build a factory without running the deployment script
 * @dev The factory does NOT hold `ADMIN_ROLE`. The gatekeeper holds it and admits only never-before-configured targets,
 *      and the factory keeps only `ADMIN_ENTRY_POINT_ROLE`, `SYNC_ROLE` and `MARKET_ROLE_GRANTOR_ROLE`. The factory also
 *      no longer binds its own selectors during `initialize`, so this helper applies them exactly as
 *      `Deploy.s.sol._wireFactoryRoles` does. A fixture that skips this leaves the factory's selectors unbound, which
 *      resolves to `ADMIN_ROLE` and makes `registerTemplate` / `executeMarketDeployment` callable only by root
 * @dev Ordering, mirroring the script: access manager, then the CREATE3 deployer, then the factory proxy address it
 *      resolves (a function of the salt alone), then the gatekeeper against that address, then the factory
 *      IMPLEMENTATION against the gatekeeper, then the proxy itself, then `wireFactoryRoles`
 * @dev `deployFactory` does the whole sequence; a fixture only needs the returned handles
 */
library FactoryScaffold {
    /**
     * @notice Stands up the CREATE3 deployer, the gatekeeper, and the factory, then wires the factory's roles
     * @dev The caller must hold `ADMIN_ROLE` on `_accessManager` (i.e. be its initial admin)
     * @param _accessManager The access manager to wire against
     * @param _salt The CREATE3 salt for the factory proxy, namespaced to this caller by the deployer
     * @return factory The initialized factory proxy
     * @return gatekeeper The gatekeeper, holding `ADMIN_ROLE` and pinned to that factory
     */
    function deployFactory(
        RoycoAccessManager _accessManager,
        bytes32 _salt
    )
        internal
        returns (RoycoFactory factory, RoycoFactoryGatekeeper gatekeeper)
    {
        // The proxy's CREATE3 address depends on the salt alone, so it is knowable before anything it points at exists.
        // That is what lets the gatekeeper and the factory each take the other as a constructor immutable
        RoycoCreate3Deployer create3Deployer = new RoycoCreate3Deployer();
        address predictedFactory = create3Deployer.predict(address(this), _salt);

        gatekeeper = new RoycoFactoryGatekeeper(address(_accessManager), predictedFactory);
        _accessManager.grantRole(ADMIN_ROLE, address(gatekeeper), 0);

        RoycoFactory impl = new RoycoFactory(address(gatekeeper));
        wireFactoryRoles(_accessManager, predictedFactory);

        factory = RoycoFactory(
            create3Deployer.deploy(_salt, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, abi.encodeCall(RoycoFactory.initialize, (address(_accessManager))))))
        );
        require(address(factory) == predictedFactory, "FactoryScaffold: factory address mismatch");
    }

    /// @notice Mirrors `Deploy.s.sol._wireFactoryRoles`: the factory's own selector bindings plus its narrow role set
    function wireFactoryRoles(RoycoAccessManager _accessManager, address _factory) internal {
        bytes4[] memory deployerSelectors = new bytes4[](2);
        deployerSelectors[0] = IRoycoFactory.executeMarketDeployment.selector;
        deployerSelectors[1] = IRoycoFactory.deployDeterministicProxy.selector;
        _accessManager.setTargetFunctionRole(_factory, deployerSelectors, DEPLOYER_ROLE);

        bytes4[] memory adminFactorySelectors = new bytes4[](2);
        adminFactorySelectors[0] = IRoycoFactory.registerTemplate.selector;
        adminFactorySelectors[1] = IRoycoFactory.disableTemplate.selector;
        _accessManager.setTargetFunctionRole(_factory, adminFactorySelectors, ADMIN_FACTORY_ROLE);

        _accessManager.setTargetFunctionRole(_factory, _one(UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE);
        _accessManager.setTargetFunctionRole(_factory, _one(IRoycoAuth.pause.selector), ADMIN_PAUSER_ROLE);
        _accessManager.setTargetFunctionRole(_factory, _one(IRoycoAuth.unpause.selector), ADMIN_UNPAUSER_ROLE);

        _accessManager.grantRole(ADMIN_ENTRY_POINT_ROLE, _factory, 0);
        _accessManager.grantRole(SYNC_ROLE, _factory, 0);
        _accessManager.grantRole(MARKET_ROLE_GRANTOR_ROLE, _factory, 0);

        // The fixture keeps the grantor role too: once the two roles' admin moves off ADMIN_ROLE, holding ADMIN_ROLE
        // alone no longer permits granting them (OZ checks a role's CURRENT admin), and fixtures grant SYNC_ROLE
        _accessManager.grantRole(MARKET_ROLE_GRANTOR_ROLE, address(this), 0);

        // The factory grants SYNC_ROLE and BURNER_ROLE during a deployment, which requires it to be their role admin
        _accessManager.setRoleAdmin(SYNC_ROLE, MARKET_ROLE_GRANTOR_ROLE);
        _accessManager.setRoleAdmin(BURNER_ROLE, MARKET_ROLE_GRANTOR_ROLE);
    }

    function _one(bytes4 _selector) private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _selector;
    }
}
