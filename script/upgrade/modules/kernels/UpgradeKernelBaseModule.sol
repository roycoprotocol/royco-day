// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../../../src/interfaces/IRoycoDayKernel.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../../../src/libraries/Units.sol";

import { UpgradeModuleBase } from "../UpgradeModuleBase.sol";

/**
 * @title UpgradeKernelBaseModule
 * @notice Abstract base for `RoycoDayKernel`-family upgrades. Concrete subclasses (one per kernel
 *         contract type) supply the kernel contract name (used in the salt), the creation code,
 *         and any kernel-type-specific snapshot/verify logic.
 *
 * @dev Payload schema (ABI-encoded by the orchestrator):
 *        abi.encode(string marketName)
 *
 *      The base module:
 *        1. Resolves the kernel proxy via `getMarketAddresses(chainId, marketName).kernel`
 *        2. Validates the proxy is a kernel (immutables non-zero, getState() succeeds)
 *        3. Lets the subclass build the new impl creation code (market-independent: the kernel implementation
 *           carries no market wiring, so nothing has to be read off the proxy to rebuild it)
 *        4. Predicts the new impl's CREATE2 address using the subclass-supplied kernel contract name
 *
 *      `snapshotState` records the common kernel surface (its market wiring + `getState()` + the live
 *      tranche↔NAV conversion rate) and concatenates the subclass-specific snapshot.
 *      `verify` decodes both halves and asserts continuity.
 */
abstract contract UpgradeKernelBaseModule is UpgradeModuleBase {
    error UpgradeKernelBaseModule__NotAKernelProxy(address proxy);
    error UpgradeKernelBaseModule__NewImplIdenticalToOld(address impl);
    error UpgradeKernelBaseModule__ImmutableChanged(string field);
    error UpgradeKernelBaseModule__StateChanged(string field);
    error UpgradeKernelBaseModule__ConversionRateChanged(string side, uint256 expected, uint256 actual);

    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT — implemented by concrete kernel modules
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Contract name embedded in the CREATE2 salt prefix; must match the live kernel impl class.
    function _kernelContractName() internal pure virtual returns (string memory);

    /// @notice Creation code for the new kernel impl
    /// @dev Takes no market input: the implementation is shared by every market on the chain
    function _kernelCreationCode() internal view virtual returns (bytes memory);

    /// @notice Module-specific snapshot bytes (e.g. oracle config, kernel-type immutables).
    function _snapshotKernelSpecific(address proxy) internal view virtual returns (bytes memory);

    /// @notice Module-specific verification given the snapshot returned by `_snapshotKernelSpecific`.
    function _verifyKernelSpecific(address proxy, bytes memory specificSnapshot) internal view virtual;

    // ═══════════════════════════════════════════════════════════════════════════
    // PREPARE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc UpgradeModuleBase
    function prepare(uint256 _chainId, string memory _saltVersion, bytes memory _payload) external view override returns (PreparedUpgrade memory prepared) {
        string memory marketName = abi.decode(_payload, (string));

        MarketAddresses memory addrs = getMarketAddresses(_chainId, marketName);
        address proxy = addrs.kernel;

        // Sanity-check the proxy really is an initialized kernel before pointing an upgrade at it
        IRoycoDayKernel.RoycoDayKernelImmutableState memory immutables = IRoycoDayKernel(proxy).getImmutableState();
        require(
            immutables.seniorTranche != address(0) && immutables.juniorTranche != address(0) && immutables.accountant != address(0),
            UpgradeKernelBaseModule__NotAKernelProxy(proxy)
        );
        IRoycoDayKernel(proxy).getState();

        address beacon = getComponentBeacons(_chainId).kernel;
        address oldImpl = _readBeaconImplementation(beacon);
        bytes memory creationCode = _kernelCreationCode();
        bytes32 salt = keccak256(abi.encodePacked("ROYCO_KERNEL_", _kernelContractName(), "_IMPLEMENTATION_", _saltVersion));

        address newImpl = _predictImpl(salt, creationCode);
        require(newImpl != oldImpl, UpgradeKernelBaseModule__NewImplIdenticalToOld(newImpl));

        string memory label = string.concat("Kernel/", marketName);

        prepared = PreparedUpgrade({
            beacon: beacon,
            oldImpl: oldImpl,
            newImpl: newImpl,
            implSalt: salt,
            implCreationCode: creationCode,
            call: UpgradeCall({
                marketName: marketName,
                target: beacon,
                callData: _buildBeaconUpgradeCallData(newImpl),
                description: string.concat("Upgrade ", label, " (", _kernelContractName(), ") implementation to ", vm.toString(newImpl))
            }),
            label: label
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SNAPSHOT / VERIFY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc UpgradeModuleBase
    function snapshotState(address _proxy) external view override returns (bytes memory) {
        return abi.encode(_snapshotCommon(_proxy), _snapshotKernelSpecific(_proxy));
    }

    /// @inheritdoc UpgradeModuleBase
    function verify(address _proxy, bytes memory _preStateSnapshot) external view override {
        (bytes memory common, bytes memory specific) = abi.decode(_preStateSnapshot, (bytes, bytes));
        _verifyCommon(_proxy, common);
        _verifyKernelSpecific(_proxy, specific);
    }

    /// @dev Common kernel state shared by every kernel type. Conversion rates are evaluated at
    ///      `1e18` tranche units; `block.timestamp` is the same for snapshot and verify (orchestrator
    ///      calls them back-to-back), so any oracle-driven math is reproducible.
    function _snapshotCommon(address _proxy) internal view returns (bytes memory) {
        IRoycoDayKernel k = IRoycoDayKernel(_proxy);
        IRoycoDayKernel.RoycoDayKernelState memory state = k.getState();
        uint256 collateralConv = NAV_UNIT.unwrap(k.convertCollateralAssetsToValue(_oneTrancheUnit()));
        IRoycoDayKernel.RoycoDayKernelImmutableState memory immutables = k.getImmutableState();
        return abi.encode(immutables.seniorTranche, immutables.juniorTranche, immutables.collateralAsset, immutables.accountant, state, collateralConv);
    }

    function _verifyCommon(address _proxy, bytes memory _snap) internal view {
        (
            address senior,
            address junior,
            address collateralAsset,
            address accountant,
            IRoycoDayKernel.RoycoDayKernelState memory state,
            uint256 collateralConvRate
        ) = abi.decode(_snap, (address, address, address, address, IRoycoDayKernel.RoycoDayKernelState, uint256));

        IRoycoDayKernel k = IRoycoDayKernel(_proxy);
        IRoycoDayKernel.RoycoDayKernelImmutableState memory post_ = k.getImmutableState();
        require(post_.seniorTranche == senior, UpgradeKernelBaseModule__ImmutableChanged("seniorTranche"));
        require(post_.juniorTranche == junior, UpgradeKernelBaseModule__ImmutableChanged("juniorTranche"));
        require(post_.collateralAsset == collateralAsset, UpgradeKernelBaseModule__ImmutableChanged("collateralAsset"));
        require(post_.accountant == accountant, UpgradeKernelBaseModule__ImmutableChanged("accountant"));

        IRoycoDayKernel.RoycoDayKernelState memory post = k.getState();
        require(post.protocolFeeRecipient == state.protocolFeeRecipient, UpgradeKernelBaseModule__StateChanged("protocolFeeRecipient"));
        require(post.stSelfLiquidationBonusWAD == state.stSelfLiquidationBonusWAD, UpgradeKernelBaseModule__StateChanged("stSelfLiquidationBonusWAD"));
        require(
            TRANCHE_UNIT.unwrap(post.totalCollateralAssets) == TRANCHE_UNIT.unwrap(state.totalCollateralAssets),
            UpgradeKernelBaseModule__StateChanged("totalCollateralAssets")
        );

        uint256 postCollateralConv = NAV_UNIT.unwrap(k.convertCollateralAssetsToValue(_oneTrancheUnit()));
        require(postCollateralConv == collateralConvRate, UpgradeKernelBaseModule__ConversionRateChanged("COLLATERAL", collateralConvRate, postCollateralConv));
    }

    function _oneTrancheUnit() private pure returns (TRANCHE_UNIT) {
        return TRANCHE_UNIT.wrap(1e18);
    }
}
