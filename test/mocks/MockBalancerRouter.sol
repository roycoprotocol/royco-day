// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
    RemoveLiquidityKind,
    RemoveLiquidityParams,
    SwapKind,
    VaultSwapParams
} from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { MockBalancerVault } from "./MockBalancerVault.sol";

/**
 * @title MockBalancerRouter
 * @notice The exogenous party's entry into the mock vault, mirroring the real Balancer Router's access shape:
 *         swaps and removals are vault operations gated onlyWhenUnlocked, so an external actor reaches them
 *         through a router that unlocks the vault, runs the operation in the callback, and settles the session
 * @dev swapSingleTokenExactIn mirrors Router.swapSingleTokenExactIn: unlock, swap, pull the input from the
 *      sender and settle it, sendTo the output. removeLiquidityProportional mirrors the proportional removal:
 *      unlock, removeLiquidity burning the sender's own BPT, sendTo both constituent legs
 * @dev The sender must approve this router for the swap input token. BPT needs no approval, the mock vault's
 *      removeLiquidity burns directly from the named owner (a documented simplification of the real
 *      router-allowance flow, the burn still requires the owner's balance)
 */
contract MockBalancerRouter {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a hook is called by anything but the vault
    error ONLY_VAULT();

    /// @notice The mock vault this router settles against
    MockBalancerVault public immutable vault;

    constructor(MockBalancerVault _vault) {
        vault = _vault;
    }

    /// @dev The swap hook's parameters, carried through unlock
    struct SwapHookParams {
        address sender;
        address pool;
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 exactAmountIn;
        uint256 minAmountOut;
    }

    /// @dev The removal hook's parameters, carried through unlock
    struct RemoveHookParams {
        address sender;
        address pool;
        uint256 exactBptAmountIn;
        uint256[2] minAmountsOut;
    }

    /// @notice Swaps an exact input amount of one pool token for the other, settling the whole session in one call
    /// @return amountOut The output amount sent to the caller
    function swapSingleTokenExactIn(
        address _pool,
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _exactAmountIn,
        uint256 _minAmountOut
    )
        external
        returns (uint256 amountOut)
    {
        amountOut = abi.decode(
            vault.unlock(abi.encodeCall(this.swapSingleTokenHook, (SwapHookParams(msg.sender, _pool, _tokenIn, _tokenOut, _exactAmountIn, _minAmountOut)))),
            (uint256)
        );
    }

    /// @notice The swap callback, dispatched by unlock from the vault's address
    function swapSingleTokenHook(SwapHookParams calldata _p) external returns (uint256 amountOut) {
        require(msg.sender == address(vault), ONLY_VAULT());
        (, uint256 amountIn, uint256 out) =
            vault.swap(VaultSwapParams(SwapKind.EXACT_IN, _p.pool, _p.tokenIn, _p.tokenOut, _p.exactAmountIn, _p.minAmountOut, ""));
        // Close the session: pull and settle the input debt, consume the output credit
        _p.tokenIn.safeTransferFrom(_p.sender, address(vault), amountIn);
        vault.settle(_p.tokenIn, amountIn);
        if (out > 0) vault.sendTo(_p.tokenOut, _p.sender, out);
        return out;
    }

    /// @notice Burns the caller's own BPT proportionally, paying both constituent legs to the caller
    /// @param _minAmountsOut Per-token floors in the pool's registration order
    /// @return amountsOut The constituent amounts paid, in registration order
    function removeLiquidityProportional(
        address _pool,
        uint256 _exactBptAmountIn,
        uint256[2] calldata _minAmountsOut
    )
        external
        returns (uint256[2] memory amountsOut)
    {
        amountsOut = abi.decode(
            vault.unlock(abi.encodeCall(this.removeLiquidityHook, (RemoveHookParams(msg.sender, _pool, _exactBptAmountIn, _minAmountsOut)))), (uint256[2])
        );
    }

    /// @notice The removal callback, dispatched by unlock from the vault's address
    function removeLiquidityHook(RemoveHookParams calldata _p) external returns (uint256[2] memory amountsOut) {
        require(msg.sender == address(vault), ONLY_VAULT());
        uint256[] memory minAmountsOut = new uint256[](2);
        (minAmountsOut[0], minAmountsOut[1]) = (_p.minAmountsOut[0], _p.minAmountsOut[1]);
        (, uint256[] memory outs,) = vault.removeLiquidity(
            RemoveLiquidityParams({
                pool: _p.pool,
                from: _p.sender,
                maxBptAmountIn: _p.exactBptAmountIn,
                minAmountsOut: minAmountsOut,
                kind: RemoveLiquidityKind.PROPORTIONAL,
                userData: ""
            })
        );
        // Consume the removal's credits by paying both legs to the sender
        IERC20[] memory tokens = vault.getPoolTokens(_p.pool);
        for (uint256 i; i < 2; ++i) {
            if (outs[i] > 0) vault.sendTo(tokens[i], _p.sender, outs[i]);
            amountsOut[i] = outs[i];
        }
    }
}
