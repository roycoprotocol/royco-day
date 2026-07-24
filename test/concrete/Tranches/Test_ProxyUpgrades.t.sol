// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Utils } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { UUPSUpgradeable } from "../../../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import { RoycoDayAccountant } from "../../../src/accountant/RoycoDayAccountant.sol";
import { RoycoBase } from "../../../src/base/RoycoBase.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { RoycoDayBalancerV3Kernel as DayKernel } from "../../../src/kernels/RoycoDayBalancerV3Kernel.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoSeniorTranche } from "../../../src/tranches/RoycoSeniorTranche.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_ProxyUpgrades_Tranches
 * @notice Exercises the UUPS upgrade surface shared by every market proxy: a role-gated upgrade must swap only
 *         the implementation pointer while every balance, supply, committed checkpoint, and authority wired into
 *         the proxy storage survives byte-for-byte, and the three rejection tiers (unauthorized caller, codeless
 *         implementation, non-UUPS target) must each leave the pointer untouched
 * @dev Seeded once in setUp: ST 100e18 and JT 30e18 vault shares at the 1.0 seed rate (coverage
 *      (100 + 30) x 0.2 / 30 = 0.8667 <= 1), plus the market base's auto-seeded quote-only LPT depth of 6 whole
 *      quote (required ceil(100e18 x 0.05) = 5e18 plus one whole-token cushion), so LPT_PROVIDER holds 6e18 LPT shares
 */
contract Test_ProxyUpgrades_Tranches is DayMarketTestBase {
    /// @dev The ERC1967 implementation slot, bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        _seedMarket(100e18, 30e18);
    }

    /// @dev Reads the implementation address a proxy currently delegates to straight out of its ERC1967 slot
    function _implOf(address _proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(_proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    /**
     * @dev Deploys fresh implementations bytecode-identical to the live ones: same creation code, same
     *      constructor args (the tranche and accountant impls bake the kernel PROXY address as an immutable, and
     *      the proxy address never changes across an upgrade, so re-running the constructors reproduces the
     *      original immutables exactly)
     */
    function _deployFreshImplementations() internal returns (RoycoSeniorTranche stImpl, DayKernel kernelImpl, RoycoDayAccountant accImpl) {
        stImpl = new RoycoSeniorTranche(address(stJtVault), address(kernel));
        accImpl = new RoycoDayAccountant(address(kernel));
        // The kernel impl constructor re-validates the live wiring (the shared collateral asset and the
        // registered two-token pool pairing the senior share), so a successful deploy is itself proof the
        // upgrade target is built against this exact market
        kernelImpl = new DayKernel(
            IRoycoDayKernel.RoycoDayKernelConstructionParams({
                seniorTranche: address(seniorTranche),
                juniorTranche: address(juniorTranche),
                collateralAsset: address(stJtVault),
                accountant: address(accountant),
                liquidityProviderTranche: address(liquidityProviderTranche),
                lptAsset: address(bpt),
                enforceVaultSharesTransferWhitelist: params.enforceWhitelistOnTransfer
            })
        );
    }

    /**
     * @notice An authorized upgrade of the senior tranche, kernel, and accountant proxies swaps only the
     *         implementation pointers: every share balance, total supply, the last committed checkpoint, and the
     *         authority survive byte-for-byte, and a deposit and redemption after the upgrade produce exactly what
     *         the never-upgraded market produces from the same state
     * @dev All value in the market lives in proxy storage (balances, the committed NAV checkpoint, the kernel's
     *      owned-asset ledgers), so an upgrade that perturbed any of it would silently move LP money. The control
     *      run replays the identical deposit and redemption on a state snapshot of the NEVER-upgraded market, so
     *      the upgraded flows are compared against an independent execution, not against themselves
     */
    function test_UpgradeToAndCall_TrancheKernelAccountantPreserveStateAndFlows() public {
        // Fund and approve the probe deposit BEFORE the snapshot so the control and post-upgrade runs replay
        // against byte-identical chain state and differ ONLY in whether the proxies were upgraded
        stJtVault.mintShares(ST_PROVIDER, 10e18);
        vm.prank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), 10e18);

        // Control run on the never-upgraded market, then rewind so the upgraded run starts from the same state
        uint256 snapshotId = vm.snapshotState();
        vm.startPrank(ST_PROVIDER);
        uint256 controlShares = seniorTranche.deposit(toTrancheUnits(10e18), ST_PROVIDER);
        AssetClaims memory controlClaims = seniorTranche.redeem(5e18, ST_PROVIDER, ST_PROVIDER);
        vm.stopPrank();
        require(vm.revertToState(snapshotId), "control-state rewind failed");

        // Hand-derived control values under the virtual-shares/value offset: flat market at the 1.0 seed rate, so
        // 10e18 vault shares are 10e18 NAV and mint floor((100e18 + 1e6) x 10e18 / (100e18 + 1)) = 10000000000000099999
        // shares. Redeeming 5e18 of the resulting 110000000000000099999 supply claims the effective NAV slice
        // floor(110e18 x 5e18 / (110000000000000099999 + 1e6)) = 4999999999999950000, converted once to collateral
        // at the identity 1.0 rate
        assertEq(controlShares, 10_000_000_000_000_099_999, "the control deposit must mint exactly the offset-adjusted quote at the 1.0 seed rate");
        assertEq(
            toUint256(controlClaims.collateralAssets),
            4_999_999_999_999_950_000,
            "the control redemption must claim exactly the offset-adjusted pro-rata vault shares"
        );

        // Pre-upgrade digests of everything an upgrade must not touch
        address oldStImpl = _implOf(address(seniorTranche));
        address oldKernelImpl = _implOf(address(kernel));
        address oldAccImpl = _implOf(address(accountant));
        bytes memory accStateBefore = abi.encode(accountant.getState());
        bytes memory kernelStateBefore = abi.encode(kernel.getState());

        (RoycoSeniorTranche freshStImpl, DayKernel freshKernelImpl, RoycoDayAccountant freshAccImpl) = _deployFreshImplementations();
        vm.startPrank(UPGRADER);
        seniorTranche.upgradeToAndCall(address(freshStImpl), "");
        kernel.upgradeToAndCall(address(freshKernelImpl), "");
        accountant.upgradeToAndCall(address(freshAccImpl), "");
        vm.stopPrank();

        // The ONLY storage words an upgrade may write are the three implementation slots
        assertNotEq(address(freshStImpl), oldStImpl, "the fresh senior tranche impl must be a new deployment");
        assertEq(_implOf(address(seniorTranche)), address(freshStImpl), "the senior tranche proxy must now delegate to the fresh impl");
        assertNotEq(address(freshKernelImpl), oldKernelImpl, "the fresh kernel impl must be a new deployment");
        assertEq(_implOf(address(kernel)), address(freshKernelImpl), "the kernel proxy must now delegate to the fresh impl");
        assertNotEq(address(freshAccImpl), oldAccImpl, "the fresh accountant impl must be a new deployment");
        assertEq(_implOf(address(accountant)), address(freshAccImpl), "the accountant proxy must now delegate to the fresh impl");

        // Share ledgers survive: the seeded 100e18 / 30e18 / 6e18 positions and supplies are proxy storage
        assertEq(seniorTranche.balanceOf(ST_PROVIDER), 100e18, "the senior LP's 100e18 shares must survive the upgrade");
        assertEq(juniorTranche.balanceOf(JT_PROVIDER), 30e18, "the junior LP's 30e18 shares must survive the upgrade");
        assertEq(liquidityProviderTranche.balanceOf(LPT_PROVIDER), 6e18, "the liquidity LP's 6e18 shares must survive the upgrade");
        assertEq(seniorTranche.totalSupply(), 100e18, "the senior supply must survive the upgrade");
        assertEq(juniorTranche.totalSupply(), 30e18, "the junior supply must survive the upgrade");
        assertEq(liquidityProviderTranche.totalSupply(), 6e18, "the liquidity supply must survive the upgrade");

        // The last committed checkpoint and the kernel's owned-asset ledgers are byte-identical: the next sync's
        // waterfall reads this checkpoint as its reference, so any drift here would misattribute PnL
        assertEq(abi.encode(accountant.getState()), accStateBefore, "the accountant's committed checkpoint must be byte-identical across the upgrade");
        assertEq(abi.encode(kernel.getState()), kernelStateBefore, "the kernel's owned-asset ledgers must be byte-identical across the upgrade");

        // The authority is the only thing standing between an attacker and every privileged surface, so it must
        // still point at the market's access manager on all three upgraded proxies
        assertEq(seniorTranche.authority(), address(accessManager), "the senior tranche's authority must survive the upgrade");
        assertEq(kernel.authority(), address(accessManager), "the kernel's authority must survive the upgrade");
        assertEq(accountant.authority(), address(accessManager), "the accountant's authority must survive the upgrade");

        // Replay the probe flows on the upgraded market: quotes and claims must match the never-upgraded control
        vm.startPrank(ST_PROVIDER);
        uint256 upgradedShares = seniorTranche.deposit(toTrancheUnits(10e18), ST_PROVIDER);
        AssetClaims memory upgradedClaims = seniorTranche.redeem(5e18, ST_PROVIDER, ST_PROVIDER);
        vm.stopPrank();
        assertEq(upgradedShares, controlShares, "a post-upgrade deposit must mint exactly what the never-upgraded control minted");
        assertEq(abi.encode(upgradedClaims), abi.encode(controlClaims), "a post-upgrade redemption must claim exactly what the never-upgraded control claimed");
    }

    /**
     * @notice The upgrade gate rejects, in order: a caller without the upgrader role, a codeless implementation,
     *         and a target with code but no valid UUPS proxiable slot, on all three proxy kinds, leaving the
     *         implementation pointer untouched every time
     * @dev An upgrade is the single most privileged operation in the market (a hostile implementation can seize
     *      every tranche's capital), and a bad target is just as fatal in the other direction: pointing the proxy
     *      at a codeless address or a non-UUPS contract bricks the market with no recovery path, because the
     *      broken implementation cannot execute the next upgrade. Tier one passes a perfectly valid fresh impl so
     *      the missing role is the only discriminant, and authorization is proven to be checked BEFORE the target
     *      is even inspected
     */
    function test_RevertIf_UpgradeUnauthorizedCodelessOrNonUUPSTarget() public {
        (RoycoSeniorTranche freshStImpl, DayKernel freshKernelImpl, RoycoDayAccountant freshAccImpl) = _deployFreshImplementations();
        address[3] memory proxies = [address(seniorTranche), address(kernel), address(accountant)];
        address[3] memory validImpls = [address(freshStImpl), address(freshKernelImpl), address(freshAccImpl)];
        address intruder = makeAddr("UPGRADE_INTRUDER");
        address codelessImpl = makeAddr("CODELESS_IMPL");

        for (uint256 i; i < 3; ++i) {
            address implBefore = _implOf(proxies[i]);

            // Tier one: no upgrader role, even with a perfectly valid target, is rejected with the caller named
            vm.prank(intruder);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, intruder));
            UUPSUpgradeable(proxies[i]).upgradeToAndCall(validImpls[i], "");

            // Tier two: an authorized upgrader pointing at an address with no code is stopped by the shared
            // base's code-length guard, catching the fat-finger that would otherwise brick the proxy forever
            vm.prank(UPGRADER);
            vm.expectRevert(RoycoBase.INVALID_IMPLEMENTATION.selector);
            UUPSUpgradeable(proxies[i]).upgradeToAndCall(codelessImpl, "");

            // Tier three: a target WITH code but no proxiableUUID (here the market's plain ERC20 quote token)
            // fails the UUPS compatibility probe, so a non-upgradeable contract can never become the implementation
            vm.prank(UPGRADER);
            vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(quoteToken)));
            UUPSUpgradeable(proxies[i]).upgradeToAndCall(address(quoteToken), "");

            // Every rejection must leave the pointer exactly where it was, no partial write survives a revert
            assertEq(_implOf(proxies[i]), implBefore, "a rejected upgrade must leave the implementation pointer untouched");
        }
    }
}
