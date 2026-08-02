// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ADMIN_FACTORY_ROLE, DEPLOYER_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { RoycoFactoryGatekeeper } from "../../../src/factory/RoycoFactoryGatekeeper.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { MockDeployerProbeTemplate } from "../../mocks/MockDeployerProbeTemplate.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { FactoryScaffold } from "../../utils/FactoryScaffold.sol";

/**
 * @title Test_FactoryMarketDeployerTransient
 * @notice Pins the lifecycle of the factory's transient `marketDeployer` binding: unset outside a deployment window,
 *         bound to the EXACT deployment caller across both template phases, cleared after success AND after an
 *         unwound failure, and the address the genesis seed is pulled from, regardless of any configured address
 * @dev A probe template reads `marketDeployer()` mid-deployment, which is the only way to observe the transient:
 *      outside the window it always reads zero
 */
contract Test_FactoryMarketDeployerTransient is Test {
    RoycoAccessManager internal am;
    RoycoFactoryGatekeeper internal gatekeeper;
    RoycoFactory internal factory;
    MockDeployerProbeTemplate internal probeTemplate;

    address internal DEPLOYER_ALPHA = makeAddr("DEPLOYER_ALPHA");
    address internal DEPLOYER_BETA = makeAddr("DEPLOYER_BETA");
    address internal BYSTANDER = makeAddr("BYSTANDER");

    function setUp() public {
        am = new RoycoAccessManager(address(this));
        (factory, gatekeeper) = FactoryScaffold.deployFactory(am, keccak256("FACTORY_PROXY"));

        am.grantRole(ADMIN_FACTORY_ROLE, address(this), 0);
        am.grantRole(DEPLOYER_ROLE, DEPLOYER_ALPHA, 0);
        am.grantRole(DEPLOYER_ROLE, DEPLOYER_BETA, 0);

        probeTemplate = new MockDeployerProbeTemplate(IRoycoFactory(address(factory)));
        factory.registerTemplate(address(probeTemplate));
        probeTemplate.setDeploymentResult(
            IRoycoProtocolTemplate.DeploymentResult({
                seniorTranche: makeAddr("ST"),
                juniorTranche: makeAddr("JT"),
                liquidityProviderTranche: makeAddr("LPT"),
                kernel: makeAddr("KERNEL"),
                accountant: makeAddr("ACCOUNTANT"),
                ydm: makeAddr("YDM"),
                lptYdm: makeAddr("LPT_YDM"),
                extras: ""
            })
        );
    }

    function _deployAs(address _deploymentCaller) internal {
        vm.prank(_deploymentCaller);
        factory.executeMarketDeployment(address(probeTemplate), "");
    }

    /// @notice Outside any deployment window the transient reads zero, before the first deployment and after every one
    function test_MarketDeployer_IsZeroOutsideADeploymentWindow() public {
        assertEq(factory.marketDeployer(), address(0), "the transient must be unset before any deployment");

        _deployAs(DEPLOYER_ALPHA);

        // Explicitly cleared at the end of executeMarketDeployment, not just at the transaction boundary
        assertEq(factory.marketDeployer(), address(0), "the transient must be cleared after a completed deployment");
    }

    /// @notice Inside the window the transient is the EXACT deployment caller, in the deploy phase and the hook phase,
    ///         and it rebinds per deployment rather than sticking to the first caller
    function test_MarketDeployer_IsTheExactCallerAcrossBothPhases() public {
        _deployAs(DEPLOYER_ALPHA);
        assertEq(probeTemplate.observedDeployerDuringDeployMarket(), DEPLOYER_ALPHA, "deployMarket must observe the deployment caller");
        assertEq(probeTemplate.observedDeployerDuringHook(), DEPLOYER_ALPHA, "the post-registration hook must observe the deployment caller");

        _deployAs(DEPLOYER_BETA);
        assertEq(probeTemplate.observedDeployerDuringDeployMarket(), DEPLOYER_BETA, "the transient must rebind to the second deployment's caller");
        assertEq(probeTemplate.observedDeployerDuringHook(), DEPLOYER_BETA, "the hook must observe the second deployment's caller");
    }

    /// @notice The seed is pulled from the deployment caller, never from any other approved account: the funder is
    ///         the transaction sender by construction, there is no configured funder address to point elsewhere
    function test_MarketDeployer_SeedIsPulledFromTheCaller_NotAnyOtherApprovedAccount() public {
        MockERC20C seedToken = new MockERC20C("Seed", "SEED", 18);
        uint256 seedAmount = 500e18;
        probeTemplate.setSeed(IERC20(address(seedToken)), seedAmount);

        // Every candidate holds funds and has approved the template, so only the transient can select the payer
        address[3] memory holders = [DEPLOYER_ALPHA, DEPLOYER_BETA, BYSTANDER];
        for (uint256 i = 0; i < holders.length; ++i) {
            seedToken.mint(holders[i], seedAmount);
            vm.prank(holders[i]);
            seedToken.approve(address(probeTemplate), seedAmount);
        }

        _deployAs(DEPLOYER_ALPHA);
        assertEq(seedToken.balanceOf(DEPLOYER_ALPHA), 0, "the seed must be pulled from the deployment caller");
        assertEq(seedToken.balanceOf(DEPLOYER_BETA), seedAmount, "a non-caller deployer must be untouched");
        assertEq(seedToken.balanceOf(BYSTANDER), seedAmount, "an approved bystander must be untouched");

        _deployAs(DEPLOYER_BETA);
        assertEq(seedToken.balanceOf(DEPLOYER_BETA), 0, "the second seed must be pulled from the second caller");
        assertEq(seedToken.balanceOf(BYSTANDER), seedAmount, "the bystander must still be untouched");
    }

    /// @notice A failed deployment unwinds the transient with the rest of the transaction state: afterwards the
    ///         window is closed and a fresh deployment binds cleanly
    function test_MarketDeployer_ClearsWhenTheDeploymentUnwinds() public {
        probeTemplate.setRevertInHook(true);
        vm.prank(DEPLOYER_ALPHA);
        vm.expectRevert(MockDeployerProbeTemplate.PROBE_HOOK_REVERTED.selector);
        factory.executeMarketDeployment(address(probeTemplate), "");

        // The revert unwound the transient binding along with every other write
        assertEq(factory.marketDeployer(), address(0), "the transient must not survive an unwound deployment");
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.executeAsFactory(makeAddr("TARGET"), "");

        // The window is fully closed, so a fresh deployment binds and completes
        probeTemplate.setRevertInHook(false);
        _deployAs(DEPLOYER_BETA);
        assertEq(probeTemplate.observedDeployerDuringHook(), DEPLOYER_BETA, "a fresh deployment must bind the new caller");
    }
}
