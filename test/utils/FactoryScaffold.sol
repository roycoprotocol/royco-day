// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { RoycoBlacklist } from "../../src/auth/RoycoBlacklist.sol";
import { RoycoAccessManager } from "../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { RoycoCreate3Deployer } from "../../src/factory/RoycoCreate3Deployer.sol";
import { RoycoFactoryGatekeeper } from "../../src/factory/RoycoFactoryGatekeeper.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ADMIN_ENTRY_POINT_ROLE, ADMIN_FACTORY_ROLE, ADMIN_PAUSER_ROLE, ADMIN_ROLE, ADMIN_UNPAUSER_ROLE, ADMIN_UPGRADER_ROLE, LPT_LP_ROLE, PUBLIC_ROLE, SYNC_ROLE } from "../../src/factory/Roles.sol";
import { IRoycoAuth } from "../../src/interfaces/IRoycoAuth.sol";
import { RoycoMarketSyncer } from "../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { RoycoDayEntryPoint } from "../../src/entrypoint/RoycoDayEntryPoint.sol";
import { IRoycoDayEntryPoint } from "../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoFactory } from "../../src/interfaces/factory/IRoycoFactory.sol";

/**
 * @title FactoryScaffold
 * @notice Stands up the access manager / gatekeeper / factory triangle the way `DeployCoreComponent` does, for the hand-rolled
 *         fixtures that build a factory without running the deployment script
 * @dev The factory does NOT hold `ADMIN_ROLE`. The gatekeeper holds it, admits only never-before-configured targets,
 *      and applies the two role grants a deployment makes; the factory keeps only `ADMIN_ENTRY_POINT_ROLE` and
 *      `SYNC_ROLE`, purely so `executeAsFactory` can forward periphery configuration. The factory also
 *      no longer binds its own selectors during `initialize`, so this helper applies them exactly as
 *      `DeployCoreComponent._wireFactoryRoles` does. A fixture that skips this leaves the factory's selectors unbound, which
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
     * @return gatekeeper The gatekeeper, holding `ADMIN_ROLE` and pinned to that factory and both periphery singletons
     * @return entryPoint The entry point singleton the gatekeeper configures each market's tranches on
     * @return marketSyncer The market syncer singleton the gatekeeper registers each market's kernel on
     */
    function deployFactory(
        RoycoAccessManager _accessManager,
        bytes32 _salt
    )
        internal
        returns (RoycoFactory factory, RoycoFactoryGatekeeper gatekeeper, IRoycoDayEntryPoint entryPoint, RoycoMarketSyncer marketSyncer)
    {
        // The proxy's CREATE3 address depends on the salt alone, so it is knowable before anything it points at exists.
        // That is what lets the gatekeeper and the factory each take the other as a constructor immutable
        RoycoCreate3Deployer create3Deployer = new RoycoCreate3Deployer();
        address predictedFactory = create3Deployer.predict(address(this), _salt);

        // The gatekeeper pins both periphery singletons, but neither can exist yet: an entry point initializes
        // against the factory, and the factory is built against this gatekeeper. CREATE3 fixes all three addresses
        // from their salts alone, so the gatekeeper takes the periphery predicted and the asserts below confirm it
        address predictedEntryPoint = create3Deployer.predict(address(this), keccak256(abi.encodePacked(_salt, "ENTRY_POINT")));
        address predictedSyncer = create3Deployer.predict(address(this), keccak256(abi.encodePacked(_salt, "MARKET_SYNCER")));

        gatekeeper = new RoycoFactoryGatekeeper(address(_accessManager), predictedFactory, predictedEntryPoint, predictedSyncer);
        _accessManager.grantRole(ADMIN_ROLE, address(gatekeeper), 0);
        // The gatekeeper, not the factory, drives the periphery, so it carries both periphery roles
        _accessManager.grantRole(ADMIN_ENTRY_POINT_ROLE, address(gatekeeper), 0);
        _accessManager.grantRole(SYNC_ROLE, address(gatekeeper), 0);

        RoycoFactory impl = new RoycoFactory(address(gatekeeper));
        wireFactoryRoles(_accessManager, predictedFactory);

        factory = RoycoFactory(
            create3Deployer.deploy(_salt, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, abi.encodeCall(RoycoFactory.initialize, (address(_accessManager))))))
        );
        require(address(factory) == predictedFactory, "FactoryScaffold: factory address mismatch");

        // The factory is live, so the periphery can initialize against it. Both must land on the addresses the
        // gatekeeper was already built around, which is the check its constructor can no longer make
        entryPoint = IRoycoDayEntryPoint(
            create3Deployer.deploy(
                keccak256(abi.encodePacked(_salt, "ENTRY_POINT")),
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(
                        address(new RoycoDayEntryPoint(predictedFactory)),
                        abi.encodeCall(RoycoDayEntryPoint.initialize, (new address[](0), new IRoycoDayEntryPoint.TrancheConfig[](0)))
                    )
                )
            )
        );
        marketSyncer = RoycoMarketSyncer(
            create3Deployer.deploy(
                keccak256(abi.encodePacked(_salt, "MARKET_SYNCER")),
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(
                        address(new RoycoMarketSyncer()), abi.encodeCall(RoycoMarketSyncer.initialize, (address(_accessManager), new address[](0)))
                    )
                )
            )
        );
        require(address(entryPoint) == predictedEntryPoint && address(marketSyncer) == predictedSyncer, "FactoryScaffold: periphery address mismatch");
    }

    /// @notice Deploys the entry point and market syncer singletons, mirroring `DeployPeripheryComponent`
    /// @param _accessManager The access manager governing both singletons
    /// @param _factory The factory address the entry point pins as its provenance registry
    function deployPeripherySingletons(
        RoycoAccessManager _accessManager,
        address _factory
    )
        internal
        returns (IRoycoDayEntryPoint entryPoint, RoycoMarketSyncer marketSyncer)
    {
        entryPoint = IRoycoDayEntryPoint(
            address(
                new ERC1967Proxy(
                    address(new RoycoDayEntryPoint(_factory)),
                    abi.encodeCall(RoycoDayEntryPoint.initialize, (new address[](0), new IRoycoDayEntryPoint.TrancheConfig[](0)))
                )
            )
        );
        marketSyncer = RoycoMarketSyncer(
            address(
                new ERC1967Proxy(
                    address(new RoycoMarketSyncer()), abi.encodeCall(RoycoMarketSyncer.initialize, (address(_accessManager), new address[](0)))
                )
            )
        );
    }

    /// @notice Mirrors `DeployCoreComponent._wireFactoryRoles`: the factory's own selector bindings plus its narrow role set
    function wireFactoryRoles(RoycoAccessManager _accessManager, address _factory) internal {
        // Market deployment is permissionless, mirroring `DeployCoreComponent._wireFactoryRoles`
        bytes4[] memory deployerSelectors = new bytes4[](1);
        deployerSelectors[0] = IRoycoFactory.executeMarketDeployment.selector;
        _accessManager.setTargetFunctionRole(_factory, deployerSelectors, PUBLIC_ROLE);

        bytes4[] memory adminFactorySelectors = new bytes4[](2);
        adminFactorySelectors[0] = IRoycoFactory.registerTemplate.selector;
        adminFactorySelectors[1] = IRoycoFactory.disableTemplate.selector;
        _accessManager.setTargetFunctionRole(_factory, adminFactorySelectors, ADMIN_FACTORY_ROLE);

        _accessManager.setTargetFunctionRole(_factory, _one(UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE);
        _accessManager.setTargetFunctionRole(_factory, _one(IRoycoAuth.pause.selector), ADMIN_PAUSER_ROLE);
        _accessManager.setTargetFunctionRole(_factory, _one(IRoycoAuth.unpause.selector), ADMIN_UNPAUSER_ROLE);

        // The genesis pool seed is a role-gated deposit the template forwards as the factory
        _accessManager.grantRole(LPT_LP_ROLE, _factory, 0);
    }

    /**
     * @notice Stands up the chain's blacklist singleton the way `DeployBlacklistComponent` does
     * @dev The template pins one blacklist for every market it deploys and rejects the null address, so a fixture that
     *      builds a template by hand needs a real one. Deployed with no sanctions list and an empty initial set, which
     *      is what the script does too: the Chainalysis list is wired later by an ops script
     * @param _accessManager The access manager governing the blacklist's admin surface
     * @return blacklist The initialized blacklist proxy
     */
    function deployBlacklist(RoycoAccessManager _accessManager) internal returns (address blacklist) {
        blacklist = address(
            new ERC1967Proxy(
                address(new RoycoBlacklist()), abi.encodeCall(RoycoBlacklist.initialize, (address(_accessManager), address(0), new address[](0)))
            )
        );
    }

    function _one(bytes4 _selector) private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _selector;
    }
}
