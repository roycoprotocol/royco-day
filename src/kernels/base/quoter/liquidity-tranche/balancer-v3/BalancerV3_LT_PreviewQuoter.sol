// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import {
    AddLiquidityKind,
    AddLiquidityParams,
    RemoveLiquidityKind,
    RemoveLiquidityParams
} from "../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { BalancerPoolToken } from "../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { VaultGuard } from "../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/VaultGuard.sol";
import { IERC20 } from "../../../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoDayKernel } from "../../../../../interfaces/IRoycoDayKernel.sol";
import { TRANCHE_UNIT, toUint256 } from "../../../../../libraries/Units.sol";
import { RoycoDayKernelLens } from "../../../RoycoDayKernelLens.sol";

/**
 * @title BalancerV3_LT_PreviewQuoter
 * @notice The Balancer V3 venue-preview half of the kernel lens: simulates the pool add/remove the kernel's execution
 *         callbacks perform, so the multi-asset LT deposit/redeem previews live on the lens (off the size-constrained
 *         kernel) while the kernel keeps the settling execution callbacks.
 * @dev `Vault.quote(data)` re-enters the CALLER, so the lens carries its own preview-only (no-settlement) callbacks.
 *      The pool's registered rate provider is still the kernel, so a lens-initiated simulation re-enters the kernel's
 *      `getRate()` and stays consistent with execution.
 */
abstract contract BalancerV3_LT_PreviewQuoter is RoycoDayKernelLens, VaultGuard {
    /// @notice The Balancer pool token (BPT) that is the liquidity tranche's asset
    address internal immutable LT_POOL;

    /// @notice Index of the Senior Tranche share token in the pool's token registration order
    uint256 internal immutable ST_SHARE_POOL_INDEX;

    /// @notice Index of the quote asset in the pool's token registration order
    uint256 internal immutable QUOTE_ASSET_POOL_INDEX;

    /// @notice Thrown when the Balancer pool is not configured with exactly two tokens
    error POOL_MUST_HAVE_TWO_TOKENS();

    /// @notice Thrown when neither of the pool's two tokens is the senior tranche share
    error INVALID_POOL_TOKEN_CONFIGURATION();

    constructor(address _roycoDayKernel)
        RoycoDayKernelLens(_roycoDayKernel)
        VaultGuard(BalancerPoolToken(IRoycoDayKernel(_roycoDayKernel).LT_ASSET()).getVault())
    {
        address ltAsset = IRoycoDayKernel(_roycoDayKernel).LT_ASSET();
        address seniorTranche = IRoycoDayKernel(_roycoDayKernel).SENIOR_TRANCHE();
        LT_POOL = ltAsset;

        // Resolve and cache the pool token indices, mirroring the kernel quoter's registration lookup
        IERC20[] memory tokens = _vault.getPoolTokens(ltAsset);
        require(tokens.length == 2, POOL_MUST_HAVE_TWO_TOKENS());
        if (address(tokens[0]) == seniorTranche) QUOTE_ASSET_POOL_INDEX = 1;
        else if (address(tokens[1]) == seniorTranche) ST_SHARE_POOL_INDEX = 1;
        else revert INVALID_POOL_TOKEN_CONFIGURATION();
    }

    // =============================
    // Preview-only Vault callbacks (no settlement) — dispatched by Vault.quote, guarded to the Vault
    // =============================

    /// @notice Simulates the unbalanced BPT mint the kernel's add would perform (query mode: no settlement, reverted by the Vault)
    function previewAddBalancerV3Liquidity(uint256 _seniorShares, uint256 _quoteAssets) external onlyVault returns (uint256 ltAssets) {
        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[ST_SHARE_POOL_INDEX] = _seniorShares;
        exactAmountsIn[QUOTE_ASSET_POOL_INDEX] = _quoteAssets;
        (, ltAssets,) = _vault.addLiquidity(
            AddLiquidityParams({
                pool: LT_POOL, to: address(this), maxAmountsIn: exactAmountsIn, minBptAmountOut: 0, kind: AddLiquidityKind.UNBALANCED, userData: ""
            })
        );
    }

    /// @notice Simulates the proportional BPT unwrap the kernel's removal would perform (query mode: no settlement, reverted by the Vault)
    function previewRemoveBalancerV3Liquidity(TRANCHE_UNIT _ltAssets) external onlyVault returns (uint256 stShares, uint256 quoteAssets) {
        uint256[] memory minAmountsOut = new uint256[](2);
        (, uint256[] memory amountsOut,) = _vault.removeLiquidity(
            RemoveLiquidityParams({
                pool: LT_POOL,
                from: address(this),
                maxBptAmountIn: toUint256(_ltAssets),
                minAmountsOut: minAmountsOut,
                kind: RemoveLiquidityKind.PROPORTIONAL,
                userData: ""
            })
        );
        stShares = amountsOut[ST_SHARE_POOL_INDEX];
        quoteAssets = amountsOut[QUOTE_ASSET_POOL_INDEX];
    }

    // =============================
    // Venue preview hooks (RoycoDayKernelLens)
    // =============================

    /// @inheritdoc RoycoDayKernelLens
    /// @dev Routes the add through the Vault's query mode (`quote`), which re-enters this contract's preview callback
    function _previewAddLiquidity(uint256 _seniorShares, uint256 _quoteAssets) internal override(RoycoDayKernelLens) returns (TRANCHE_UNIT ltAssets) {
        bytes memory callbackReturnData = _vault.quote(abi.encodeCall(this.previewAddBalancerV3Liquidity, (_seniorShares, _quoteAssets)));
        assembly ("memory-safe") {
            ltAssets := mload(add(callbackReturnData, 0x20))
        }
    }

    /// @inheritdoc RoycoDayKernelLens
    /// @dev Routes the removal through the Vault's query mode (`quote`), which re-enters this contract's preview callback
    function _previewRemoveLiquidity(TRANCHE_UNIT _ltAssets) internal override(RoycoDayKernelLens) returns (uint256 stShares, uint256 quoteAssets) {
        bytes memory callbackReturnData = _vault.quote(abi.encodeCall(this.previewRemoveBalancerV3Liquidity, (_ltAssets)));
        assembly ("memory-safe") {
            stShares := mload(add(callbackReturnData, 0x20))
            quoteAssets := mload(add(callbackReturnData, 0x40))
        }
    }
}
