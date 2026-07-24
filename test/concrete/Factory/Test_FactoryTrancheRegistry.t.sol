// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ADMIN_FACTORY_ROLE, ADMIN_ROLE, DEPLOYER_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { MockDeploymentTemplate } from "../../mocks/MockDeploymentTemplate.sol";
import { UninitializedERC1967Proxy } from "../../mocks/UninitializedERC1967Proxy.sol";

/// @title Test_FactoryTrancheRegistry
/// @notice Pins how `RoycoFactory.executeMarketDeployment` validates a template's `DeploymentResult` and populates the
///         tranche-to-kernel registry. Every market has all three tranches (senior, junior, liquidity), so a result
///         missing the kernel or any required tranche is rejected
contract Test_FactoryTrancheRegistry is Test {
    AccessManager internal am;
    RoycoFactory internal factory;
    MockDeploymentTemplate internal template;

    address internal FACTORY_ADMIN = makeAddr("FACTORY_ADMIN");
    address internal DEPLOYER = makeAddr("DEPLOYER");

    function setUp() public {
        // This test contract is the AccessManager admin (ADMIN_ROLE).
        am = new AccessManager(address(this));

        // `initialize` requires the factory to already hold ADMIN_ROLE on the AM, so deploy the proxy uninitialized,
        // grant its (now known) address ADMIN_ROLE, then initialize.
        RoycoFactory impl = new RoycoFactory();
        factory = RoycoFactory(address(new UninitializedERC1967Proxy(address(impl))));
        am.grantRole(ADMIN_ROLE, address(factory), 0);
        factory.initialize(address(am));

        // Grant the roles the factory's initialize() bound to its gated selectors.
        am.grantRole(ADMIN_FACTORY_ROLE, FACTORY_ADMIN, 0);
        am.grantRole(DEPLOYER_ROLE, DEPLOYER, 0);

        // A canned-result template bound to this factory: registration only checks the template points back at
        // this factory, so no initialization step is needed.
        template = new MockDeploymentTemplate(IRoycoFactory(address(factory)));
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));
    }

    /// @dev Builds a canned deployment result with the given tranche/kernel addresses and inert non-market fields
    function _result(address _st, address _jt, address _lt, address _kernel) internal returns (IRoycoProtocolTemplate.DeploymentResult memory) {
        return IRoycoProtocolTemplate.DeploymentResult({
            seniorTranche: _st,
            juniorTranche: _jt,
            liquidityProviderTranche: _lt,
            kernel: _kernel,
            accountant: makeAddr("ACCOUNTANT"),
            ydm: makeAddr("YDM"),
            lptYdm: address(0),
            extras: ""
        });
    }

    /// @dev Executes a deployment of the canned result as the deployer, expecting success
    function _deploy(IRoycoProtocolTemplate.DeploymentResult memory _r) internal {
        template.setDeploymentResult(_r);
        vm.prank(DEPLOYER);
        factory.executeMarketDeployment(address(template), "");
    }

    /// A template result without a kernel is rejected: every tranche registers against the kernel, so there is
    /// nothing to anchor a market to
    function test_ExecuteMarketDeployment_RevertIf_ResultHasNoKernel() external {
        template.setDeploymentResult(_result(makeAddr("ST"), makeAddr("JT"), makeAddr("LPT"), address(0)));
        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.INVALID_DEPLOYMENT_RESULT.selector);
        factory.executeMarketDeployment(address(template), "");
    }

    /// A template result without a senior tranche is rejected: every market is anchored on protected senior capital,
    /// so a result with no ST names no valid market
    function test_ExecuteMarketDeployment_RevertIf_ResultHasNoSeniorTranche() external {
        template.setDeploymentResult(_result(address(0), makeAddr("JT"), makeAddr("LPT"), makeAddr("KERNEL")));
        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.INVALID_DEPLOYMENT_RESULT.selector);
        factory.executeMarketDeployment(address(template), "");
    }

    /// A template result without a liquidity provider tranche is rejected: every market has a liquidity provider tranche, so a result
    /// missing it names no valid market
    function test_ExecuteMarketDeployment_RevertIf_ResultHasNoLiquidityProviderTranche() external {
        template.setDeploymentResult(_result(makeAddr("ST"), makeAddr("JT"), address(0), makeAddr("KERNEL")));
        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.INVALID_DEPLOYMENT_RESULT.selector);
        factory.executeMarketDeployment(address(template), "");
    }

    /// A complete result registers all three tranches (senior, junior, liquidity) against the market's kernel
    function test_ExecuteMarketDeployment_AllThreeTranches_RegisterAgainstKernel() external {
        address st = makeAddr("ST");
        address jt = makeAddr("JT");
        address lt = makeAddr("LPT");
        address kernel = makeAddr("KERNEL");
        _deploy(_result(st, jt, lt, kernel));

        assertEq(factory.trancheToKernel(st), kernel, "senior key -> kernel");
        assertEq(factory.trancheToKernel(jt), kernel, "junior key -> kernel");
        assertEq(factory.trancheToKernel(lt), kernel, "liquidity key -> kernel");
    }
}
