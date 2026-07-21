// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRateProvider } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IERC20MultiTokenErrors } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IERC20MultiTokenErrors.sol";
import { IVaultErrors } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";
import {
    AddLiquidityKind,
    AddLiquidityParams,
    RemoveLiquidityKind,
    RemoveLiquidityParams
} from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { MockBPT } from "./MockBPT.sol";

/**
 * @title MockBalancerVault
 * @notice Balancer V3 vault test mock satisfying every call the kernel's venue layer makes, with real-vault semantics where production depends on them
 * @dev unlock calls the callback FROM this vault's address (the venue callbacks are onlyVault) and bubbles callback reverts verbatim
 * @dev quote has revert-discard semantics via an external self-call, so preview state mutations roll back, but it does NOT enforce
 *      the real vault's eth_call-only gate because kernel previews self-call quote mid-transaction in tests
 * @dev The debt/credit session ledger mirrors the real vault, every delta opened by addLiquidity, removeLiquidity, and sendTo must be
 *      closed by settle or sendTo before unlock returns, else BalanceNotSettled
 * @dev The complete fidelity table (mirrored semantics vs deliberate deltas such as linear fair-value add pricing,
 *      no swap surface, and no hook layer) lives in test/mocks/README.md
 */
contract MockBalancerVault {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @dev Which venue entrypoints are forced to revert
    enum RevertMode {
        NONE,
        ADD,
        REMOVE,
        ALL
    }

    /// @dev Carries a successful quote callback's returndata out of the discarded self-call frame
    error QuoteResult(bytes result);

    /// @notice Thrown when the quote self-call frame returns instead of reverting, which is unreachable by construction
    error QUOTE_DID_NOT_REVERT();

    /// @notice Thrown when quoteAndRevertExternal is called by anything but this vault itself
    error ONLY_SELF();

    /// @notice Thrown by addLiquidity when revert mode is ADD or ALL
    error FORCED_ADD_REVERT();

    /// @notice Thrown by removeLiquidity when revert mode is REMOVE or ALL
    error FORCED_REMOVE_REVERT();

    /// @notice Thrown when an add or remove passes token amounts whose length is not exactly two
    error INVALID_AMOUNTS_LENGTH();

    /// @notice Thrown when the transfer fee exceeds 100%
    error INVALID_FEE_BPS();

    /// @notice Thrown when a BPT balance cannot cover the transfer or burn
    error BPT_INSUFFICIENT_BALANCE();

    /// @notice Thrown when a BPT allowance cannot cover the transferFrom
    error BPT_INSUFFICIENT_ALLOWANCE();

    // =============================
    // State
    // =============================

    /**
     * @notice The minimum BPT total supply every pool must retain, mirroring the real vault's _POOL_MINIMUM_TOTAL_SUPPLY
     * @dev The real vault mints this amount to address(0) at pool initialization (ERC20MultiToken._mintMinimumSupplyReserve)
     *      and reverts any mint or burn that would leave the total supply below it (_ensurePoolMinimumTotalSupply)
     */
    uint256 public constant POOL_MINIMUM_TOTAL_SUPPLY = 1e6;

    /// @dev Whether each pool has been registered
    mapping(address pool => bool registered) private _registered;

    /// @dev Whether a pool has been seeded with its genesis liquidity, mirroring the real vault's initialization latch
    mapping(address pool => bool initialized) private _initialized;

    /// @dev Each registered pool's two tokens, in registration order
    mapping(address pool => IERC20[2] tokens) private _poolTokens;

    /// @dev Each registered pool's token balances, in registration order
    mapping(address pool => uint256[2] balances) private _poolBalances;

    /// @dev The vault-side BPT total supply ledger
    mapping(address pool => uint256 supply) private _bptTotalSupply;

    /// @dev The vault-side BPT balance ledger
    mapping(address pool => mapping(address account => uint256 balance)) private _bptBalances;

    /// @dev The vault-side BPT allowance ledger
    mapping(address pool => mapping(address owner => mapping(address spender => uint256 amount))) private _bptAllowances;

    /// @dev The token reserves the vault believes it holds, settle credits the difference between the live balance and this
    mapping(IERC20 token => uint256 reserves) private _reservesOf;

    /// @dev The unlock nesting depth, the vault is unlocked while it is positive
    uint256 private _unlockDepth;

    /// @dev The open debt (positive) or credit (negative) per token within the current unlock session
    mapping(IERC20 token => int256 delta) private _tokenDelta;

    /// @dev The number of tokens with a non-zero session delta, must be zero when unlock returns
    uint256 private _nonzeroDeltaCount;

    /// @notice The haircut applied to the fair-value BPT out on UNBALANCED adds, in basis points
    uint16 public unbalancedFeeBps;

    /// @dev The one-shot BPT-out override for the next add, and whether it is armed
    uint256 private _nextBptOutOverride;
    bool private _nextBptOutOverrideArmed;

    /// @notice The active forced-revert mode
    RevertMode public revertMode;

    /// @dev Per-token WAD prices used for fair-value add pricing, zero reads as the WAD (1.0) default
    mapping(address token => uint256 priceWAD) private _tokenPriceWAD;

    /// @dev Per-token live rate providers, when set the token's price is read from the provider on every operation and the static price is ignored
    mapping(address token => address rateProvider) private _tokenRateProvider;

    // =============================
    // Registry
    // =============================

    /// @notice Registers a pool with its two tokens in registration order, a test setter standing in for the real registration flow
    function registerPool(address _pool, IERC20[2] calldata _tokens) external {
        require(!_registered[_pool], IVaultErrors.PoolAlreadyRegistered(_pool));
        _registered[_pool] = true;
        _poolTokens[_pool] = _tokens;
    }

    /// @notice Returns whether the pool is registered, validated by the kernel quoter constructor
    function isPoolRegistered(address _pool) external view returns (bool) {
        return _registered[_pool];
    }

    /// @notice Returns whether the pool has been seeded with its genesis liquidity, routing the kernel's add between initialize and addLiquidity
    function isPoolInitialized(address _pool) external view returns (bool) {
        return _initialized[_pool];
    }

    /// @notice Returns the pool's tokens in registration order, validated by the kernel quoter constructor
    function getPoolTokens(address _pool) external view returns (IERC20[] memory tokens) {
        require(_registered[_pool], IVaultErrors.PoolNotRegistered(_pool));
        tokens = new IERC20[](2);
        tokens[0] = _poolTokens[_pool][0];
        tokens[1] = _poolTokens[_pool][1];
    }

    /// @notice Returns the pool's token balances in registration order, read by MockBPTOracle's AUTO mode and tests
    function getPoolBalances(address _pool) external view returns (uint256[2] memory) {
        return _poolBalances[_pool];
    }

    // =============================
    // BPT Ledger (backs MockBPT, token == msg.sender on the mutating calls)
    // =============================

    /// @notice Returns the pool token's total supply from the vault ledger
    function totalSupply(address _token) external view returns (uint256) {
        return _bptTotalSupply[_token];
    }

    /// @notice Returns the account's pool token balance from the vault ledger
    function balanceOf(address _token, address _account) external view returns (uint256) {
        return _bptBalances[_token][_account];
    }

    /// @notice Returns the pool token allowance from the vault ledger
    /// @dev Mirrors the real ERC20MultiToken exemption, an owner can spend anything without approval, so owner == spender reads max
    function allowance(address _token, address _owner, address _spender) external view returns (uint256) {
        if (_owner == _spender) return type(uint256).max;
        return _bptAllowances[_token][_owner][_spender];
    }

    /// @notice Moves pool tokens on behalf of the calling pool token contract
    function transfer(address _owner, address _to, uint256 _amount) external returns (bool) {
        _bptTransfer(msg.sender, _owner, _to, _amount);
        return true;
    }

    /// @notice Sets a pool token allowance on behalf of the calling pool token contract
    function approve(address _owner, address _spender, uint256 _amount) external returns (bool) {
        _bptAllowances[msg.sender][_owner][_spender] = _amount;
        MockBPT(msg.sender).emitApproval(_owner, _spender, _amount);
        return true;
    }

    /// @notice Moves pool tokens using the spender's allowance on behalf of the calling pool token contract
    /// @dev Mirrors the real ERC20MultiToken exemption, the owner spends without approval, so _from == _spender skips the allowance check
    function transferFrom(address _spender, address _from, address _to, uint256 _amount) external returns (bool) {
        uint256 currentAllowance = _from == _spender ? type(uint256).max : _bptAllowances[msg.sender][_from][_spender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= _amount, BPT_INSUFFICIENT_ALLOWANCE());
            _bptAllowances[msg.sender][_from][_spender] = currentAllowance - _amount;
        }
        _bptTransfer(msg.sender, _from, _to, _amount);
        return true;
    }

    // =============================
    // Unlock / Settle / SendTo (the transient accounting session)
    // =============================

    /**
     * @notice Unlocks the vault and executes the caller's callback FROM this vault's address, so onlyVault callbacks pass
     * @dev Callback reverts bubble verbatim, and every debt or credit opened during the session must be settled before returning
     * @param _data The calldata dispatched back into the caller
     * @return result The callback's raw returndata
     */
    function unlock(bytes calldata _data) external returns (bytes memory result) {
        _unlockDepth++;
        (bool success, bytes memory returnData) = msg.sender.call(_data);
        if (!success) _bubbleRevert(returnData);
        require(_nonzeroDeltaCount == 0, IVaultErrors.BalanceNotSettled());
        _unlockDepth--;
        return returnData;
    }

    /**
     * @notice Credits the caller for tokens transferred into the vault, closing open debt
     * @dev credit = min(live balance - tracked reserves, hint), and the reserves snap to the live balance, mirroring the real vault
     * @param _token The token being settled
     * @param _amountHint The maximum credit the caller expects
     * @return credit The credit granted
     */
    function settle(IERC20 _token, uint256 _amountHint) external returns (uint256 credit) {
        _ensureUnlocked();
        uint256 reservesBefore = _reservesOf[_token];
        uint256 currentReserves = _token.balanceOf(address(this));
        _reservesOf[_token] = currentReserves;
        credit = currentReserves - reservesBefore;
        if (credit > _amountHint) credit = _amountHint;
        _accountDelta(_token, -int256(credit));
    }

    /// @notice Transfers tokens out of the vault to the recipient, opening debt against the caller's session credit
    function sendTo(IERC20 _token, address _to, uint256 _amount) external {
        _ensureUnlocked();
        _accountDelta(_token, int256(_amount));
        _reservesOf[_token] -= _amount;
        _token.safeTransfer(_to, _amount);
    }

    // =============================
    // Add / Remove Liquidity
    // =============================

    /**
     * @notice Performs an UNBALANCED add, treating maxAmountsIn as the exact amounts in, mirroring the real vault
     * @dev BPT out is the armed one-shot override if set, else the fair value of the amounts in at the per-token WAD prices
     *      converted to BPT at the pool's current NAV per BPT (1:1 with NAV on an empty pool), haircut by unbalancedFeeBps
     * @dev Reverts BptAmountOutBelowMin with the real vault's error shape when the mint falls under minBptAmountOut
     */
    /**
     * @notice Initializes a registered pool by seeding its genesis balances, mirroring VaultExtension.initialize
     * @dev Prices the seed at fair value with NO unbalanced-add haircut (the real initialize mints the invariant and charges no swap fee),
     *      mints the POOL_MINIMUM_TOTAL_SUPPLY dead BPT to the null address first, and checks minBptAmountOut against the NET
     *      amount minted to the receiver, so the slippage bound applies to what the receiver actually gets
     * @dev Opens the token debts the callback must settle, exactly like addLiquidity, and honors the armed one-shot BPT override
     *      and the forced-revert mode so venue-failure fixtures drive this branch identically
     */
    function initialize(
        address _pool,
        address _to,
        IERC20[] memory _tokens,
        uint256[] memory _exactAmountsIn,
        uint256 _minBptAmountOut,
        bytes memory
    )
        external
        returns (uint256 bptAmountOut)
    {
        _ensureUnlocked();
        require(_registered[_pool], IVaultErrors.PoolNotRegistered(_pool));
        require(!_initialized[_pool], IVaultErrors.PoolAlreadyInitialized(_pool));
        require(revertMode != RevertMode.ADD && revertMode != RevertMode.ALL, FORCED_ADD_REVERT());
        require(_tokens.length == 2 && _exactAmountsIn.length == 2, INVALID_AMOUNTS_LENGTH());

        IERC20[2] storage tokens = _poolTokens[_pool];
        uint256[2] storage balances = _poolBalances[_pool];

        // The passed tokens must match the pool's registration order, the real vault's cross-check on the seed's ordering
        for (uint256 i; i < 2; ++i) {
            require(address(_tokens[i]) == address(tokens[i]), IVaultErrors.TokensMismatch(_pool, address(_tokens[i]), address(tokens[i])));
        }

        // Price the genesis BPT, the armed one-shot override wins as the net mint, else fair value less the dead minimum
        if (_nextBptOutOverrideArmed) {
            bptAmountOut = _nextBptOutOverride;
            _nextBptOutOverrideArmed = false;
            _nextBptOutOverride = 0;
        } else {
            uint256 grossBptOut = _tokenValueWAD(tokens[0], _exactAmountsIn[0]) + _tokenValueWAD(tokens[1], _exactAmountsIn[1]);
            require(grossBptOut >= POOL_MINIMUM_TOTAL_SUPPLY, IERC20MultiTokenErrors.PoolTotalSupplyTooLow(grossBptOut));
            bptAmountOut = grossBptOut - POOL_MINIMUM_TOTAL_SUPPLY;
        }
        require(bptAmountOut >= _minBptAmountOut, IVaultErrors.BptAmountOutBelowMin(bptAmountOut, _minBptAmountOut));

        // Commit the seed, credit the pool balances, open the token debts the callback must settle, and mint the BPT with its dead minimum
        balances[0] += _exactAmountsIn[0];
        balances[1] += _exactAmountsIn[1];
        if (_exactAmountsIn[0] > 0) _accountDelta(tokens[0], int256(_exactAmountsIn[0]));
        if (_exactAmountsIn[1] > 0) _accountDelta(tokens[1], int256(_exactAmountsIn[1]));
        _mintMinimumSupplyReserve(_pool);
        _mintBpt(_pool, _to, bptAmountOut);
        _initialized[_pool] = true;
    }

    function addLiquidity(AddLiquidityParams memory params) external returns (uint256[] memory amountsIn, uint256 bptAmountOut, bytes memory returnData) {
        _ensureUnlocked();
        require(_registered[params.pool], IVaultErrors.PoolNotRegistered(params.pool));
        require(revertMode != RevertMode.ADD && revertMode != RevertMode.ALL, FORCED_ADD_REVERT());
        require(params.kind == AddLiquidityKind.UNBALANCED, IVaultErrors.InvalidAddLiquidityKind());
        require(params.maxAmountsIn.length == 2, INVALID_AMOUNTS_LENGTH());

        // For UNBALANCED adds the requested amounts are exact, not upper bounds
        amountsIn = params.maxAmountsIn;

        IERC20[2] storage tokens = _poolTokens[params.pool];
        uint256[2] storage balances = _poolBalances[params.pool];

        // Price the BPT out, the armed one-shot override wins, else fair value less the unbalanced-add haircut
        if (_nextBptOutOverrideArmed) {
            bptAmountOut = _nextBptOutOverride;
            _nextBptOutOverrideArmed = false;
            _nextBptOutOverride = 0;
        } else {
            uint256 valueInWAD = _tokenValueWAD(tokens[0], amountsIn[0]) + _tokenValueWAD(tokens[1], amountsIn[1]);
            uint256 supply = _bptTotalSupply[params.pool];
            uint256 poolValueWAD = _tokenValueWAD(tokens[0], balances[0]) + _tokenValueWAD(tokens[1], balances[1]);
            // On an empty or worthless pool the BPT is minted 1:1 with the 18-decimal NAV added
            bptAmountOut = (supply == 0 || poolValueWAD == 0) ? valueInWAD : valueInWAD.mulDiv(supply, poolValueWAD, Math.Rounding.Floor);
            bptAmountOut = (bptAmountOut * (10_000 - unbalancedFeeBps)) / 10_000;
        }
        require(bptAmountOut >= params.minBptAmountOut, IVaultErrors.BptAmountOutBelowMin(bptAmountOut, params.minBptAmountOut));

        // Commit the add, credit the pool balances, open the token debts the callback must settle, and mint the BPT
        balances[0] += amountsIn[0];
        balances[1] += amountsIn[1];
        if (amountsIn[0] > 0) _accountDelta(tokens[0], int256(amountsIn[0]));
        if (amountsIn[1] > 0) _accountDelta(tokens[1], int256(amountsIn[1]));
        _mintBpt(params.pool, params.to, bptAmountOut);

        returnData = "";
    }

    /**
     * @notice Performs a PROPORTIONAL removal, treating maxBptAmountIn as the exact BPT burned, mirroring the real vault
     * @dev amountsOut[i] = poolBalance[i] * bptIn / supply with floor rounding
     * @dev Reverts AmountOutBelowMin with the real vault's error shape when a constituent falls under its floor
     */
    function removeLiquidity(RemoveLiquidityParams memory params) external returns (uint256 bptAmountIn, uint256[] memory amountsOut, bytes memory returnData) {
        _ensureUnlocked();
        require(_registered[params.pool], IVaultErrors.PoolNotRegistered(params.pool));
        require(revertMode != RevertMode.REMOVE && revertMode != RevertMode.ALL, FORCED_REMOVE_REVERT());
        require(params.kind == RemoveLiquidityKind.PROPORTIONAL, IVaultErrors.InvalidRemoveLiquidityKind());
        require(params.minAmountsOut.length == 2, INVALID_AMOUNTS_LENGTH());

        // For PROPORTIONAL removals the requested BPT is exact, not an upper bound
        bptAmountIn = params.maxBptAmountIn;

        IERC20[2] storage tokens = _poolTokens[params.pool];
        uint256[2] storage balances = _poolBalances[params.pool];
        uint256 supply = _bptTotalSupply[params.pool];
        require(supply > 0, IVaultErrors.PoolNotInitialized(params.pool));

        // Compute the proportional constituent claims with floor rounding and enforce the per-token floors
        amountsOut = new uint256[](2);
        for (uint256 i; i < 2; ++i) {
            amountsOut[i] = balances[i].mulDiv(bptAmountIn, supply, Math.Rounding.Floor);
            require(amountsOut[i] >= params.minAmountsOut[i], IVaultErrors.AmountOutBelowMin(tokens[i], amountsOut[i], params.minAmountsOut[i]));
        }

        // Commit the removal, burn the BPT, debit the pool balances, and open the credits sendTo will consume
        _burnBpt(params.pool, params.from, bptAmountIn);
        balances[0] -= amountsOut[0];
        balances[1] -= amountsOut[1];
        if (amountsOut[0] > 0) _accountDelta(tokens[0], -int256(amountsOut[0]));
        if (amountsOut[1] > 0) _accountDelta(tokens[1], -int256(amountsOut[1]));

        returnData = "";
    }

    // =============================
    // Quote (preview with revert-discard semantics)
    // =============================

    /**
     * @notice Simulates a callback with revert-discard semantics, any state the preview mutates is rolled back by the inner revert
     * @dev Runs the same dispatch as unlock through an external self-call whose success payload travels out in a QuoteResult revert
     * @dev Deliberately does NOT enforce the real vault's eth_call-only gate, kernel previews self-call quote mid-transaction in tests
     * @param _data The calldata dispatched back into the caller
     * @return result The callback's raw returndata, with all preview state mutations discarded
     */
    function quote(bytes calldata _data) external returns (bytes memory result) {
        try this.quoteAndRevertExternal(_data, msg.sender) {
            revert QUOTE_DID_NOT_REVERT();
        } catch (bytes memory reason) {
            // A QuoteResult payload carries the successful callback's returndata, anything else bubbles verbatim
            if (reason.length >= 4 && bytes4(reason) == QuoteResult.selector) {
                assembly ("memory-safe") {
                    let fullLength := mload(reason)
                    reason := add(reason, 0x04)
                    mstore(reason, sub(fullLength, 4))
                }
                result = abi.decode(reason, (bytes));
            } else {
                _bubbleRevert(reason);
            }
        }
    }

    /**
     * @notice The quote self-call frame, unlocks the vault, runs the callback, and always reverts to discard its state mutations
     * @dev Only callable by this vault itself, callback failures bubble verbatim, callback successes revert QuoteResult(returndata)
     * @param _data The calldata dispatched back into the original quote caller
     * @param _caller The original quote caller to dispatch into
     */
    function quoteAndRevertExternal(bytes calldata _data, address _caller) external {
        require(msg.sender == address(this), ONLY_SELF());
        _unlockDepth++;
        (bool success, bytes memory returnData) = _caller.call(_data);
        if (!success) _bubbleRevert(returnData);
        revert QuoteResult(returnData);
    }

    // =============================
    // Test Knobs
    // =============================

    /// @notice Sets the haircut applied to the fair-value BPT out on UNBALANCED adds, in basis points
    function setUnbalancedFeeBps(uint16 _unbalancedFeeBps) external {
        require(_unbalancedFeeBps <= 10_000, INVALID_FEE_BPS());
        unbalancedFeeBps = _unbalancedFeeBps;
    }

    /// @notice Arms a one-shot BPT-out override consumed by the next committed add, driving the slippage gate deterministically
    function setNextBptOutOverride(uint256 _bptAmountOut) external {
        _nextBptOutOverride = _bptAmountOut;
        _nextBptOutOverrideArmed = true;
    }

    /// @notice Disarms a previously armed BPT-out override that was never consumed
    function clearNextBptOutOverride() external {
        _nextBptOutOverride = 0;
        _nextBptOutOverrideArmed = false;
    }

    /// @notice Sets the forced-revert mode on the venue entrypoints (NONE, ADD, REMOVE, ALL)
    function setRevertMode(RevertMode _mode) external {
        revertMode = _mode;
    }

    /// @notice Sets a token's WAD price for fair-value add pricing, zero resets to the WAD (1.0) default
    /// @dev Shadowed by a live rate provider when one is set for the token
    function setTokenPriceWAD(address _token, uint256 _priceWAD) external {
        _tokenPriceWAD[_token] = _priceWAD;
    }

    /**
     * @notice Wires a live rate provider for a token, address(0) unwires it back to the static price
     * @dev Mirrors production E-CLP pricing: a rate-scaled token is priced through IRateProvider.getRate read live
     *      on every pool operation, so mid-transaction rate refreshes (like the kernel's post-sync senior share
     *      rate) are seen by the very next add or remove exactly as the real pool would see them
     */
    function setTokenRateProvider(address _token, address _rateProvider) external {
        _tokenRateProvider[_token] = _rateProvider;
    }

    /// @notice Returns a token's effective WAD price, the live rate provider when wired, else the static price
    function getTokenPriceWAD(address _token) public view returns (uint256) {
        address rateProvider = _tokenRateProvider[_token];
        if (rateProvider != address(0)) return IRateProvider(rateProvider).getRate();
        uint256 priceWAD = _tokenPriceWAD[_token];
        return priceWAD == 0 ? WAD : priceWAD;
    }

    /**
     * @notice Mints pool tokens and seeds pool depth without the kernel, the external-LP helper for fixtures
     * @dev Pulls the token amounts from the caller so the vault's reserves stay truthful for later settle and sendTo flows
     * @dev The FIRST mint for a pool additionally mints POOL_MINIMUM_TOTAL_SUPPLY dead BPT to address(0), mirroring the real
     *      vault's pool initialization (VaultExtension.initialize -> ERC20MultiToken._mintMinimumSupplyReserve), so the total
     *      supply is the requested amount plus the dead minimum and burns can never drain the pool token below the minimum
     * @param _pool The registered pool to seed
     * @param _to The recipient of the minted BPT
     * @param _bptAmount The BPT amount to mint
     * @param _tokenAmounts The token amounts to pull into the pool, in registration order
     */
    function mintPoolTokensTo(address _pool, address _to, uint256 _bptAmount, uint256[2] calldata _tokenAmounts) external {
        require(_registered[_pool], IVaultErrors.PoolNotRegistered(_pool));
        for (uint256 i; i < 2; ++i) {
            if (_tokenAmounts[i] == 0) continue;
            IERC20 token = _poolTokens[_pool][i];
            token.safeTransferFrom(msg.sender, address(this), _tokenAmounts[i]);
            _reservesOf[token] = token.balanceOf(address(this));
            _poolBalances[_pool][i] += _tokenAmounts[i];
        }
        if (_bptTotalSupply[_pool] == 0) _mintMinimumSupplyReserve(_pool);
        _mintBpt(_pool, _to, _bptAmount);
        // Fixture seeding is the pool's genesis liquidity, so it latches initialization exactly like the kernel-driven seed
        _initialized[_pool] = true;
    }

    /**
     * @notice Donates tokens into one side of a pool without minting BPT, a swap-free composition-drift helper
     * @dev Pulls the tokens from the caller so the vault's reserves stay truthful
     * @param _pool The registered pool to donate into
     * @param _token The pool token to donate, must be one of the pool's two constituents
     * @param _amount The amount to donate
     */
    function injectPoolBalance(address _pool, IERC20 _token, uint256 _amount) external {
        require(_registered[_pool], IVaultErrors.PoolNotRegistered(_pool));
        uint256 index;
        if (_poolTokens[_pool][0] == _token) index = 0;
        else if (_poolTokens[_pool][1] == _token) index = 1;
        else revert IVaultErrors.TokenNotRegistered(_token);

        _token.safeTransferFrom(msg.sender, address(this), _amount);
        _reservesOf[_token] = _token.balanceOf(address(this));
        _poolBalances[_pool][index] += _amount;
    }

    // =============================
    // Internal Logic
    // =============================

    /// @notice Reverts with the real vault's error shape when called outside an unlock session
    function _ensureUnlocked() internal view {
        require(_unlockDepth > 0, IVaultErrors.VaultIsNotUnlocked());
    }

    /// @notice Applies a signed delta to a token's session ledger, tracking how many tokens remain unsettled
    function _accountDelta(IERC20 _token, int256 _delta) internal {
        if (_delta == 0) return;
        int256 current = _tokenDelta[_token];
        int256 next = current + _delta;
        if (current == 0) _nonzeroDeltaCount++;
        if (next == 0) _nonzeroDeltaCount--;
        _tokenDelta[_token] = next;
    }

    /// @notice Values a token amount in 18-decimal NAV terms at its effective WAD price
    function _tokenValueWAD(IERC20 _token, uint256 _amount) internal view returns (uint256) {
        if (_amount == 0) return 0;
        return _amount.mulDiv(getTokenPriceWAD(address(_token)), 10 ** IERC20Metadata(address(_token)).decimals(), Math.Rounding.Floor);
    }

    /// @notice Moves pool tokens in the vault ledger and emits the Transfer event from the pool token
    function _bptTransfer(address _pool, address _from, address _to, uint256 _amount) internal {
        require(_bptBalances[_pool][_from] >= _amount, BPT_INSUFFICIENT_BALANCE());
        _bptBalances[_pool][_from] -= _amount;
        _bptBalances[_pool][_to] += _amount;
        MockBPT(_pool).emitTransfer(_from, _to, _amount);
    }

    /// @notice Mints pool tokens in the vault ledger and emits the Transfer event from the pool token
    /// @dev Enforces the real vault's minimum-total-supply floor on the post-mint supply (ERC20MultiToken._mint)
    function _mintBpt(address _pool, address _to, uint256 _amount) internal {
        uint256 newTotalSupply = _bptTotalSupply[_pool] + _amount;
        _ensurePoolMinimumTotalSupply(newTotalSupply);
        _bptTotalSupply[_pool] = newTotalSupply;
        _bptBalances[_pool][_to] += _amount;
        MockBPT(_pool).emitTransfer(address(0), _to, _amount);
    }

    /**
     * @notice Mints the dead minimum-supply reserve to address(0) on a pool's first mint
     * @dev Mirrors ERC20MultiToken._mintMinimumSupplyReserve, the real vault locks POOL_MINIMUM_TOTAL_SUPPLY at
     *      pool initialization so no burn can ever bring the supply back under the minimum
     */
    function _mintMinimumSupplyReserve(address _pool) internal {
        _bptTotalSupply[_pool] += POOL_MINIMUM_TOTAL_SUPPLY;
        _bptBalances[_pool][address(0)] += POOL_MINIMUM_TOTAL_SUPPLY;
        MockBPT(_pool).emitTransfer(address(0), address(0), POOL_MINIMUM_TOTAL_SUPPLY);
    }

    /// @notice Burns pool tokens in the vault ledger and emits the Transfer event from the pool token
    /// @dev Enforces the real vault's minimum-total-supply floor on the post-burn supply (ERC20MultiToken._burn)
    function _burnBpt(address _pool, address _from, uint256 _amount) internal {
        require(_bptBalances[_pool][_from] >= _amount, BPT_INSUFFICIENT_BALANCE());
        uint256 newTotalSupply = _bptTotalSupply[_pool] - _amount;
        _ensurePoolMinimumTotalSupply(newTotalSupply);
        _bptBalances[_pool][_from] -= _amount;
        _bptTotalSupply[_pool] = newTotalSupply;
        MockBPT(_pool).emitTransfer(_from, address(0), _amount);
    }

    /// @notice Reverts with the real vault's error shape when a mint or burn would leave the supply under the minimum
    /// @dev Mirrors ERC20MultiToken._ensurePoolMinimumTotalSupply byte-for-byte (IERC20MultiTokenErrors.PoolTotalSupplyTooLow)
    function _ensurePoolMinimumTotalSupply(uint256 _newTotalSupply) internal pure {
        require(_newTotalSupply >= POOL_MINIMUM_TOTAL_SUPPLY, IERC20MultiTokenErrors.PoolTotalSupplyTooLow(_newTotalSupply));
    }

    /// @notice Reverts with the provided returndata verbatim, preserving the inner frame's exact error
    function _bubbleRevert(bytes memory _returnData) internal pure {
        assembly ("memory-safe") {
            revert(add(_returnData, 0x20), mload(_returnData))
        }
    }
}
