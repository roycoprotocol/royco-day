// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Initializable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoycoDayEntryPoint } from "../../../src/entrypoint/RoycoDayEntryPoint.sol";
import { ADMIN_ENTRY_POINT_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { TrancheType } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { MockRoycoFactory } from "../../mocks/MockRoycoFactory.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointConstructionAndAdmin
 * @notice Construction, initialization, tranche provenance validation, admin configuration, the production access
 *         model on every gated selector, view getters, and UUPS upgrade gating for the entry point
 */
contract Test_EntryPointConstructionAndAdmin is EntryPointTestBase {
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
    }

    // ---------------------------------------------------------------------
    // Construction and initialization
    // ---------------------------------------------------------------------

    function test_constructor_revertsOnNullFactory() public {
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new RoycoDayEntryPoint(address(0));
    }

    function test_initialize_wiresAuthorityAndFactory_initialConfigsArriveThroughFactory() public view {
        assertEq(entryPoint.ROYCO_FACTORY(), address(entryPointFactory), "the factory must be the constructor-set immutable");
        assertEq(IAccessManaged(address(entryPoint)).authority(), address(accessManager), "the authority must be the factory's ROYCO_AUTHORITY");

        // The fixture initializes the entry point empty and routes the initial configs through the factory
        // (mirroring production market deployments); the stored configs must be enriched with the tranche's
        // asset, kernel, and type
        IRoycoDayEntryPoint.EnrichedTrancheConfig memory config = entryPoint.getTrancheConfig(address(liquidityProviderTranche));
        assertEq(config.asset, address(bpt), "the LPT config must cache the tranche asset");
        assertEq(config.kernel, address(kernel), "the LPT config must cache the market kernel");
        assertEq(uint8(config.trancheType), uint8(TrancheType.LIQUIDITY_PROVIDER), "the LPT config must cache the tranche type");
        assertTrue(config.baseConfig.enabled, "the LPT must be enabled by the factory-routed initial configuration");
    }

    function test_initialize_cannotBeReinitialized() public {
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        RoycoDayEntryPoint(address(entryPoint)).initialize(tranches, configs);
    }

    function test_initialize_revertsOnLengthMismatch() public {
        RoycoDayEntryPoint impl = new RoycoDayEntryPoint(address(entryPointFactory));
        (address[] memory tranches,) = _defaultTrancheConfigs();
        vm.expectRevert(IRoycoDayEntryPoint.ARRAY_LENGTH_MISMATCH.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(RoycoDayEntryPoint.initialize, (tranches, new IRoycoDayEntryPoint.TrancheConfig[](1))));
    }

    // ---------------------------------------------------------------------
    // Tranche provenance validation
    // ---------------------------------------------------------------------

    function test_modifyTrancheConfigs_revertsForNonFactoryDeployedTranche() public {
        // An address the factory does not map to a kernel is not a Royco tranche
        address[] memory tranches = new address[](1);
        tranches[0] = makeAddr("NOT_A_TRANCHE");
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](1);
        vm.expectRevert(IRoycoDayEntryPoint.INVALID_TRANCHE.selector);
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.modifyTrancheConfigs(tranches, configs);
    }

    function test_modifyTrancheConfigs_revertsOnNullTranche() public {
        address[] memory tranches = new address[](1);
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](1);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.modifyTrancheConfigs(tranches, configs);
    }

    function test_modifyTrancheConfigs_updatesConfigAndEmits() public {
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        configs[0].depositDelaySeconds = 2 hours;
        configs[0].enabled = false;

        vm.expectEmit(address(entryPoint));
        emit IRoycoDayEntryPoint.TrancheConfigUpdated(tranches[0], configs[0]);
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.modifyTrancheConfigs(tranches, configs);

        IRoycoDayEntryPoint.EnrichedTrancheConfig memory stored = entryPoint.getTrancheConfig(tranches[0]);
        assertEq(stored.baseConfig.depositDelaySeconds, 2 hours, "the delay update must be stored");
        assertFalse(stored.baseConfig.enabled, "the enable flag update must be stored");
    }

    // ---------------------------------------------------------------------
    // Factory-routed configuration
    // ---------------------------------------------------------------------

    function test_factoryRoute_modifyTrancheConfigs_succeeds() public {
        // The factory (holding ADMIN_ENTRY_POINT_ROLE) can apply config changes, as production deployments do
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        configs[1].redemptionDelaySeconds = 3 hours;
        entryPointFactory.executeAsFactory(address(entryPoint), abi.encodeCall(IRoycoDayEntryPoint.modifyTrancheConfigs, (tranches, configs)));

        assertEq(entryPoint.getTrancheConfig(tranches[1]).baseConfig.redemptionDelaySeconds, 3 hours, "the factory-routed config update must be stored");
    }

    function test_factoryRoute_revertsWhenFactoryLacksRole() public {
        // Without ADMIN_ENTRY_POINT_ROLE the factory's forwarded call fails the entry point's access check, which
        // the factory's dispatch bubbles verbatim
        accessManager.revokeRole(ADMIN_ENTRY_POINT_ROLE, address(entryPointFactory));

        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(entryPointFactory)));
        entryPointFactory.executeAsFactory(address(entryPoint), abi.encodeCall(IRoycoDayEntryPoint.modifyTrancheConfigs, (tranches, configs)));
    }

    // ---------------------------------------------------------------------
    // Access model
    // ---------------------------------------------------------------------

    function test_adminSelectors_revertForUnauthorizedCallers() public {
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        uint256[] memory amounts = new uint256[](3);

        // modifyTrancheConfigs is ADMIN_ENTRY_POINT_ROLE-gated
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, USER_A));
        vm.prank(USER_A);
        entryPoint.modifyTrancheConfigs(tranches, configs);

        // collectProtocolFees is ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE-gated (even the config admin is unauthorized)
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ENTRY_POINT_ADMIN));
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.collectProtocolFees(tranches, amounts, ENTRY_POINT_ADMIN);

        // pause/unpause are pauser/unpauser-gated
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, USER_A));
        vm.prank(USER_A);
        IRoycoAuth(address(entryPoint)).pause();
    }

    function test_collectProtocolFees_revertsOnNullReceiverAndLengthMismatch() public {
        address[] memory tranches = new address[](1);
        tranches[0] = address(seniorTranche);
        uint256[] memory amounts = new uint256[](1);

        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        vm.prank(FEE_COLLECTOR);
        entryPoint.collectProtocolFees(tranches, amounts, address(0));

        vm.expectRevert(IRoycoDayEntryPoint.ARRAY_LENGTH_MISMATCH.selector);
        vm.prank(FEE_COLLECTOR);
        entryPoint.collectProtocolFees(tranches, new uint256[](2), FEE_COLLECTOR);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function test_views_emptyReadsReturnDefaults() public view {
        assertEq(entryPoint.getLastRequestNonce(), 0, "the nonce must start at zero");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, 1).assets), 0, "an unknown deposit request must read empty");
        assertEq(entryPoint.getRedemptionRequest(USER_A, 1).shares, 0, "an unknown redemption request must read empty");
        assertEq(entryPoint.getProtocolFeeSharesPendingCollection(address(seniorTranche)), 0, "fee accruals must start at zero");
        assertEq(entryPoint.getTrancheConfig(address(0xdead)).asset, address(0), "an unknown tranche config must read empty");
    }

    // ---------------------------------------------------------------------
    // UUPS upgrades
    // ---------------------------------------------------------------------

    function test_upgrade_onlyUpgraderRole_andStateSurvives() public {
        // Register a request so post-upgrade state can be verified
        (uint256 nonce,) = _requestDepositDefault(USER_A, address(juniorTranche), 10 * stUnit);

        RoycoDayEntryPoint newImpl = new RoycoDayEntryPoint(address(entryPointFactory));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, USER_A));
        vm.prank(USER_A);
        UUPSUpgradeable(address(entryPoint)).upgradeToAndCall(address(newImpl), "");

        vm.prank(UPGRADER);
        UUPSUpgradeable(address(entryPoint)).upgradeToAndCall(address(newImpl), "");

        assertEq(entryPoint.getLastRequestNonce(), nonce, "the request nonce must survive the upgrade");
        assertEq(toUint256(entryPoint.getDepositRequest(USER_A, nonce).assets), 10 * stUnit, "the queued request must survive the upgrade");
    }
}
