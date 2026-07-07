// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ADMIN_FACTORY_ROLE, ADMIN_ROLE, DEPLOYER_ROLE } from "../../../src/factory/RolesConfiguration.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { MockDeploymentTemplate } from "../../mocks/MockDeploymentTemplate.sol";
import { MockKernelTrancheSet } from "../../mocks/MockKernelTrancheSet.sol";
import { UninitializedERC1967Proxy } from "../../mocks/UninitializedERC1967Proxy.sol";

/// @title Test_FactoryTrancheRegistry
/// @notice Pins how `RoycoFactory.executeMarketDeployment` populates the tranche-to-kernel registry when a
///         template's `DeploymentResult` carries a zero tranche member
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

        // A canned-result template bound to this factory: empty-array initialize is accepted (the component loop
        // runs zero times but the initializer version still lands at 1), which is all registration checks for.
        template = new MockDeploymentTemplate(IRoycoFactory(address(factory)));
        template.initialize(new bytes32[](0), new bytes[](0));
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));
    }

    /**
     * @notice A template result with `liquidityTranche == address(0)` (the documented shape for a market without a
     *         liquidity tranche) registers the ZERO ADDRESS as a tranche key, so `getMarket(address(0))` stops
     *         returning the documented all-zeros unknown-tranche sentinel and instead resolves a live market.
     * @dev CURRENT: `executeMarketDeployment` writes all three result tranches into `trancheToKernel`
     *      unconditionally, so `trancheToKernel[address(0)] = kernel` lands whenever any tranche member is zero,
     *      and `getMarket(address(0))` — whose unknown-tranche branch only fires when the mapping is EMPTY — reads
     *      the kernel's tranche getters and returns nonzero components for a key that names no tranche.
     *      EXPECTED: zero tranche members are rejected (or skipped), leaving `address(0)` unmapped so the
     *      all-zeros sentinel holds for it. Severity is bounded by the trust boundary: only an admin-registered
     *      template can reach this write, so the poisoned key requires a template that emits a zero member —
     *      but that is exactly the advertised ST/JT-only result shape, not a malicious one.
     */
    function test_DIVERGENCE_22_ZeroTrancheFromTemplate_PoisonsZeroAddressRegistryKeyAndGetMarketSentinel() external {
        address seniorTranche = makeAddr("SENIOR_TRANCHE");
        address juniorTranche = makeAddr("JUNIOR_TRANCHE");
        // The kernel stand-in reports the same ST/JT set the result carries, and no liquidity tranche.
        MockKernelTrancheSet kernel = new MockKernelTrancheSet(seniorTranche, juniorTranche, address(0));

        // An ST/JT-only market result: `liquidityTranche` is zero exactly as the result struct documents for
        // markets without a liquidity tranche.
        template.setDeploymentResult(
            IRoycoProtocolTemplate.DeploymentResult({
                seniorTranche: seniorTranche,
                juniorTranche: juniorTranche,
                liquidityTranche: address(0),
                kernel: address(kernel),
                accountant: makeAddr("ACCOUNTANT"),
                ydm: makeAddr("YDM"),
                ltYdm: address(0),
                extras: ""
            })
        );

        // Empty params: the mock returns its canned result without any component deployment.
        vm.prank(DEPLOYER);
        factory.executeMarketDeployment(address(template), "");

        // The two real tranche keys resolve to the kernel, as intended.
        assertEq(factory.trancheToKernel(seniorTranche), address(kernel), "senior key -> kernel");
        assertEq(factory.trancheToKernel(juniorTranche), address(kernel), "junior key -> kernel");

        // DIVERGENCE: the zero-tranche write poisoned the zero-address key. `trancheToKernel(address(0))` should be
        // address(0) (no tranche lives at the zero address). FIXED: the zero-tranche registry write is skipped, so
        // the zero-address key is never poisoned.
        assertEq(factory.trancheToKernel(address(0)), address(0), "zero-address key must not be poisoned");

        // FIXED (consequence): `getMarket(address(0))` hits its unknown-tranche branch and returns all zeros.
        (address st, address jt, address lt, address k) = factory.getMarket(address(0));
        assertEq(st, address(0), "sentinel intact: senior does not resolve for the zero key");
        assertEq(jt, address(0), "sentinel intact: junior does not resolve for the zero key");
        assertEq(lt, address(0), "sentinel intact: liquidity does not resolve for the zero key");
        assertEq(k, address(0), "sentinel intact: kernel does not resolve for the zero key");
    }
}
