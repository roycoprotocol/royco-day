// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { Ownable } from "../../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { RoycoDayAccountant } from "../../../src/accountant/RoycoDayAccountant.sol";
import { UpgradeableBeacon } from "../../../lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { RoycoDayBalancerV3Kernel as DayKernel } from "../../../src/kernels/RoycoDayBalancerV3Kernel.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoSeniorTranche } from "../../../src/tranches/RoycoSeniorTranche.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_ProxyUpgrades_Tranches
 * @notice Exercises the beacon upgrade surface shared by every market proxy: a role-gated upgrade must move only the
 *         implementation the beacon points at, while every balance, supply, committed checkpoint, and authority in
 *         each proxy's storage survives byte-for-byte; both rejection tiers (unauthorized caller, codeless
 *         implementation) must leave the beacon untouched; and one upgrade must move every market at once
 * @dev Seeded once in setUp: ST 100e18 and JT 30e18 vault shares at the 1.0 seed rate (coverage
 *      (100 + 30) x 0.2 / 30 = 0.8667 <= 1), plus the market base's auto-seeded quote-only LPT depth of 6 whole
 *      quote (required ceil(100e18 x 0.05) = 5e18 plus one whole-token cushion), so LPT_PROVIDER holds 6e18 LPT shares
 */
contract Test_ProxyUpgrades_Tranches is DayMarketTestBase {
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        _seedMarket(100e18, 30e18);
    }

    /// @dev Upgrades a beacon the way governance does: the access manager owns every beacon, so an upgrade is an
    ///      `execute` through the manager, which is where the upgrader role and its execution delay are enforced
    function _upgradeBeacon(UpgradeableBeacon _beacon, address _newImplementation) internal {
        accessManager.execute(address(_beacon), abi.encodeCall(UpgradeableBeacon.upgradeTo, (_newImplementation)));
    }

    /// @dev The implementation every proxy reading from this beacon currently delegates to
    function _implOf(UpgradeableBeacon _beacon) internal view returns (address) {
        return _beacon.implementation();
    }

    /**
     * @dev Deploys fresh implementations bytecode-identical to the live ones. Every implementation is now
     *      market-independent — the market wiring lives in each proxy's storage, untouched by an upgrade — so the
     *      only construction input anywhere is the kernel's Balancer Vault
     */
    function _deployFreshImplementations() internal returns (RoycoSeniorTranche stImpl, DayKernel kernelImpl, RoycoDayAccountant accImpl) {
        stImpl = new RoycoSeniorTranche();
        accImpl = new RoycoDayAccountant();
        kernelImpl = new DayKernel(IVault(address(balancerVault)));
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
    function test_BeaconUpgrade_TrancheKernelAccountantPreserveStateAndFlows() public {
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
        // 10e18 vault shares are 10e18 NAV and mint floor((100e18 + 1) x 10e18 / (100e18 + 1)) = 10000000000000000000
        // shares. Redeeming 5e18 of the resulting 110000000000000000000 supply claims the effective NAV slice
        // floor(110e18 x 5e18 / (110000000000000000000 + 1)) = 4999999999999999999, converted once to collateral
        // at the identity 1.0 rate
        assertEq(controlShares, 10_000_000_000_000_000_000, "the control deposit must mint exactly the offset-adjusted quote at the 1.0 seed rate");
        assertEq(
            toUint256(controlClaims.collateralAssets),
            4_999_999_999_999_999_999,
            "the control redemption must claim exactly the offset-adjusted pro-rata vault shares"
        );

        // Pre-upgrade digests of everything an upgrade must not touch
        address oldStImpl = _implOf(stBeacon);
        address oldKernelImpl = _implOf(kernelBeacon);
        address oldAccImpl = _implOf(accountantBeacon);
        bytes memory accStateBefore = abi.encode(accountant.getState());
        bytes memory kernelStateBefore = abi.encode(kernel.getState());

        (RoycoSeniorTranche freshStImpl, DayKernel freshKernelImpl, RoycoDayAccountant freshAccImpl) = _deployFreshImplementations();
        vm.startPrank(UPGRADER);
        _upgradeBeacon(stBeacon, address(freshStImpl));
        _upgradeBeacon(kernelBeacon, address(freshKernelImpl));
        _upgradeBeacon(accountantBeacon, address(freshAccImpl));
        vm.stopPrank();

        // The ONLY state an upgrade may write is the implementation each beacon points at
        assertNotEq(address(freshStImpl), oldStImpl, "the fresh senior tranche impl must be a new deployment");
        assertEq(_implOf(stBeacon), address(freshStImpl), "the senior tranche beacon must now point at the fresh impl");
        assertNotEq(address(freshKernelImpl), oldKernelImpl, "the fresh kernel impl must be a new deployment");
        assertEq(_implOf(kernelBeacon), address(freshKernelImpl), "the kernel beacon must now point at the fresh impl");
        assertNotEq(address(freshAccImpl), oldAccImpl, "the fresh accountant impl must be a new deployment");
        assertEq(_implOf(accountantBeacon), address(freshAccImpl), "the accountant beacon must now point at the fresh impl");

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
     * @notice The upgrade gate rejects a caller without the upgrader role and a codeless implementation, on every
     *         component beacon, leaving the implementation each beacon points at untouched every time
     * @dev An upgrade is the single most privileged operation in the protocol, and under a beacon it is strictly more
     *      so: one call moves every market of that component type at once. A bad target is just as fatal in the other
     *      direction, since pointing a beacon at a codeless address bricks every market that reads from it with no
     *      recovery path. Tier one passes a perfectly valid fresh impl so the missing role is the only discriminant,
     *      proving authorization is checked BEFORE the target is inspected
     * @dev There is no beacon analogue of the old third tier (a contract with code but no `proxiableUUID`): a beacon
     *      performs no proxiable-slot probe, so any contract with code is an acceptable target
     */
    function test_RevertIf_BeaconUpgradeUnauthorizedOrCodeless() public {
        (RoycoSeniorTranche freshStImpl, DayKernel freshKernelImpl, RoycoDayAccountant freshAccImpl) = _deployFreshImplementations();
        UpgradeableBeacon[3] memory beacons = [stBeacon, kernelBeacon, accountantBeacon];
        address[3] memory validImpls = [address(freshStImpl), address(freshKernelImpl), address(freshAccImpl)];
        address intruder = makeAddr("UPGRADE_INTRUDER");
        address codelessImpl = makeAddr("CODELESS_IMPL");

        for (uint256 i; i < 3; ++i) {
            address implBefore = _implOf(beacons[i]);

            // Tier one: no upgrader role, even with a perfectly valid target, is rejected by the access manager
            vm.prank(intruder);
            vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedCall.selector, intruder, address(beacons[i]), UpgradeableBeacon.upgradeTo.selector));
            accessManager.execute(address(beacons[i]), abi.encodeCall(UpgradeableBeacon.upgradeTo, (validImpls[i])));

            // Tier one (b): the beacon is owned by the access manager, so even the upgrader cannot call it directly
            vm.prank(UPGRADER);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, UPGRADER));
            beacons[i].upgradeTo(validImpls[i]);

            // Tier two: an authorized upgrader pointing at an address with no code is stopped by the beacon's
            // code-length guard, catching the fat-finger that would otherwise brick every market at once
            vm.prank(UPGRADER);
            vm.expectRevert(abi.encodeWithSelector(UpgradeableBeacon.BeaconInvalidImplementation.selector, codelessImpl));
            _upgradeBeacon(beacons[i], codelessImpl);

            // Every rejection must leave the pointer exactly where it was, no partial write survives a revert
            assertEq(_implOf(beacons[i]), implBefore, "a rejected upgrade must leave the implementation untouched");
        }
    }

    /**
     * @notice One beacon upgrade moves every market that reads from it, which is the whole point of the pattern
     * @dev Deploys a second, independent market against the SAME beacons the fixture market uses, then upgrades the
     *      senior tranche beacon once and asserts both markets' senior proxies resolve to the new implementation. This
     *      is the property that replaces per-market upgrades, and the reason a staged rollout is no longer possible
     */
    function test_BeaconUpgrade_MovesEveryMarketReadingFromIt() public {
        address firstMarketSenior = address(seniorTranche);
        address secondMarketSenior =
            _deployTrancheProxy(address(stBeacon), "Second Market Senior", "RST2", address(kernel), address(stJtVault));

        address freshImpl = address(new RoycoSeniorTranche());
        vm.prank(UPGRADER);
        _upgradeBeacon(stBeacon, freshImpl);

        assertEq(_implOf(stBeacon), freshImpl, "the beacon must point at the fresh implementation");
        assertEq(RoycoSeniorTranche(firstMarketSenior).kernel(), address(kernel), "the first market's senior proxy must still resolve its own state");
        assertEq(
            RoycoSeniorTranche(secondMarketSenior).kernel(), address(kernel), "the second market's senior proxy must resolve through the same beacon"
        );
    }
}
