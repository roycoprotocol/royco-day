// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { IBasePool } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IBasePool.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IVaultAdmin } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultAdmin.sol";
import { Rounding } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRoycoFactory } from "../../interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../interfaces/factory/IRoycoProtocolTemplate.sol";

/**
 * @title RoycoDayMarketGenesis
 * @notice Operator entry points that decide a Day market's Balancer pool genesis, rather than leaving it to whoever
 *         calls the venue's public `initialize` first
 * @dev A market's pool is created uninitialized and nothing else in the repo initializes it, so between deployment
 *      and the first liquidity provider deposit anyone may set the pool's opening composition. A dust genesis is
 *      permanent: the pool cannot be initialized twice, a token balance of exactly zero makes later unbalanced adds
 *      that supply zero of that token revert with an arithmetic underflow, and a tiny opening invariant puts every
 *      real deposit over the E-CLP's cap on invariant growth for a single unbalanced add
 * @dev The two entry points here remove that window without requiring the deployment and the seeding to happen
 *      together. `deployMarketPaused` deploys the market and pauses its pool in one transaction, so the pool is
 *      never both live and uninitialized. `unpauseAndInitialize` reopens it and sets the genesis in one transaction,
 *      whenever the operator is ready and has the quote
 * @dev This contract needs three roles on the market authority: the role that guards
 *      `RoycoFactory.executeMarketDeployment`, plus `ADMIN_PAUSER_ROLE` and `ADMIN_UNPAUSER_ROLE`, which are the
 *      roles bound to the Balancer Vault's `pausePool` and `unpausePool` for this market
 */
contract RoycoDayMarketGenesis {
    using SafeERC20 for IERC20;

    /**
     * @notice The market's liquidity requirement, applied after the pool is seeded rather than at deployment
     * @custom:field accountant - The market's accountant, or the null address to leave the requirement alone
     * @custom:field minLiquidityWAD - The share of senior tranche NAV required in the liquidity provider tranche's
     *               inventory, scaled to WAD
     */
    struct LiquidityRequirement {
        address accountant;
        uint64 minLiquidityWAD;
    }

    /// @notice The E-CLP's cap on invariant growth for one unbalanced add (GyroECLPMath.MAX_INVARIANT_RATIO)
    uint256 public constant MAX_INVARIANT_RATIO = 5e18;

    /// @notice The Royco factory this contract deploys markets through
    IRoycoFactory public immutable ROYCO_FACTORY;

    /// @notice The Balancer V3 Vault the markets' pools are registered with
    IVault public immutable BALANCER_V3_VAULT;

    /// @notice Thrown when a genesis would leave a pool token at exactly zero
    error GENESIS_LEG_IS_ZERO();

    /// @notice Thrown when the seed is too small for the first deposit it is expected to accept
    error GENESIS_TOO_SMALL_FOR_FIRST_DEPOSIT(uint256 invariantRatio, uint256 maxInvariantRatio);

    /// @notice Thrown when the deployed market reports no Balancer pool
    error NO_POOL_IN_DEPLOYMENT_RESULT();

    /// @notice Thrown when a vault callback is invoked by anything other than the Vault
    error ONLY_VAULT();

    /// @notice Emitted when a market is deployed with its pool paused
    event MarketDeployedPaused(address indexed template, address indexed kernel, address indexed pool);

    /// @notice Emitted when a paused pool is reopened and seeded
    event PoolGenesisSet(address indexed pool, uint256[] amountsIn, uint256 bptOut);

    /// @notice Emitted when the market's liquidity requirement is applied after seeding
    event LiquidityRequirementRaised(address indexed accountant, uint64 minLiquidityWAD);

    modifier onlyVault() {
        require(msg.sender == address(BALANCER_V3_VAULT), ONLY_VAULT());
        _;
    }

    constructor(IRoycoFactory _roycoFactory, IVault _balancerV3Vault) {
        ROYCO_FACTORY = _roycoFactory;
        BALANCER_V3_VAULT = _balancerV3Vault;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP ONE: DEPLOY WITH THE POOL CLOSED
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploys a market and pauses its Balancer pool in the same transaction
     * @dev The pool is registered during `executeMarketDeployment` and paused before this call returns, so it is
     *      never reachable by an outside initializer. Balancer allows a registered pool to be paused before it is
     *      initialized, and `Vault.initialize` rejects a paused pool
     * @param _template The market deployment template to run
     * @param _params The template's ABI-encoded market parameters
     * @return result The template's deployment result
     * @return pool The market's Balancer pool, now registered and paused
     */
    function deployMarketPaused(
        address _template,
        bytes calldata _params
    )
        external
        returns (IRoycoProtocolTemplate.DeploymentResult memory result, address pool)
    {
        result = ROYCO_FACTORY.executeMarketDeployment(_template, _params);

        pool = _poolOf(result);
        require(pool != address(0), NO_POOL_IN_DEPLOYMENT_RESULT());

        _callAsAuthority(abi.encodeCall(IVaultAdmin.pausePool, (pool)));

        emit MarketDeployedPaused(_template, result.kernel, pool);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP TWO: REOPEN AND SEED
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Unpauses a market's pool and sets its genesis composition in the same transaction
     * @dev Both amounts must be nonzero. A token balance of exactly zero is only reachable at initialization, and
     *      once reached it is permanent, so this is the one place the condition can be enforced
     * @dev When `_firstDepositAmounts` is supplied, the seed is checked against the growth cap that the first
     *      deposit will face, which is the condition that makes the seed large enough to be usable
     * @dev The caller must hold both tokens and have approved this contract for the seeded amounts
     * @param _pool The market's Balancer pool, paused and uninitialized
     * @param _exactAmountsIn The genesis balances, in the pool's token registration order
     * @param _minBptAmountOut The minimum pool tokens the genesis must mint
     * @param _bptRecipient The recipient of the minted pool tokens
     * @param _firstDepositAmounts The amounts of the first deposit the seed must be able to accept, in the pool's
     *        token registration order. Pass an empty array to skip the check
     * @param _liquidityRequirement The market's liquidity requirement to apply once the pool holds inventory. Pass a
     *        null accountant to leave the requirement alone
     * @return bptOut The pool tokens minted, net of the minimum supply Balancer burns at initialization
     */
    function unpauseAndInitialize(
        address _pool,
        uint256[] calldata _exactAmountsIn,
        uint256 _minBptAmountOut,
        address _bptRecipient,
        uint256[] calldata _firstDepositAmounts,
        LiquidityRequirement calldata _liquidityRequirement
    )
        external
        returns (uint256 bptOut)
    {
        // Neither token may be left at zero, whatever the caller intended
        for (uint256 i = 0; i < _exactAmountsIn.length; ++i) {
            require(_exactAmountsIn[i] > 0, GENESIS_LEG_IS_ZERO());
        }

        // The seed has to be large enough that the first deposit stays under the pool's growth cap
        if (_firstDepositAmounts.length > 0) {
            _requireSeedCarriesFirstDeposit(_pool, _exactAmountsIn, _firstDepositAmounts);
        }

        _callAsAuthority(abi.encodeCall(IVaultAdmin.unpausePool, (_pool)));

        bytes memory hookCall = abi.encodeCall(this.initializeHook, (_pool, msg.sender, _bptRecipient, _exactAmountsIn, _minBptAmountOut));
        bptOut = abi.decode(BALANCER_V3_VAULT.unlock(hookCall), (uint256));

        emit PoolGenesisSet(_pool, _exactAmountsIn, bptOut);

        // Raise the liquidity requirement only now that the pool holds inventory. Applied in this order because a
        // nonzero requirement against an empty liquidity provider tranche saturates the market's liquidity
        // utilization, which makes every senior tranche deposit revert, and senior deposits are what mint the
        // senior shares a compliant genesis needs. Raising it before seeding is a deadlock
        if (_liquidityRequirement.accountant != address(0)) {
            IAccessManager(ROYCO_FACTORY.ROYCO_AUTHORITY())
                .execute(_liquidityRequirement.accountant, abi.encodeCall(IRoycoDayAccountantLike.setMinLiquidity, (_liquidityRequirement.minLiquidityWAD)));
            emit LiquidityRequirementRaised(_liquidityRequirement.accountant, _liquidityRequirement.minLiquidityWAD);
        }
    }

    /**
     * @notice Vault callback performing the initialization inside the unlocked Vault
     * @dev Only callable by the Balancer V3 Vault, and only reachable through `unpauseAndInitialize`
     */
    function initializeHook(
        address _pool,
        address _payer,
        address _bptRecipient,
        uint256[] calldata _exactAmountsIn,
        uint256 _minBptAmountOut
    )
        external
        onlyVault
        returns (uint256 bptOut)
    {
        IERC20[] memory tokens = BALANCER_V3_VAULT.getPoolTokens(_pool);
        bptOut = BALANCER_V3_VAULT.initialize(_pool, _bptRecipient, tokens, _exactAmountsIn, _minBptAmountOut, "");

        // Settle what the genesis owes the Vault by pulling the tokens from the caller
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (_exactAmountsIn[i] > 0) {
                tokens[i].safeTransferFrom(_payer, address(BALANCER_V3_VAULT), _exactAmountsIn[i]);
                BALANCER_V3_VAULT.settle(tokens[i], _exactAmountsIn[i]);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SIZING
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns the invariant growth a first deposit would cause against a proposed seed
     * @dev The pool rejects an unbalanced add whose growth ratio exceeds `MAX_INVARIANT_RATIO`, so a seed is large
     *      enough exactly when this is at or below that cap. Because the invariant scales linearly with the
     *      balances, the requirement works out to the seed being about a quarter of the deposit by value
     * @param _pool The market's Balancer pool
     * @param _seedAmounts The proposed genesis balances, in the pool's token registration order
     * @param _firstDepositAmounts The first deposit's amounts, in the pool's token registration order
     * @return invariantRatio The growth ratio the first deposit would produce, scaled to WAD
     */
    function previewFirstDepositInvariantRatio(
        address _pool,
        uint256[] memory _seedAmounts,
        uint256[] memory _firstDepositAmounts
    )
        public
        view
        returns (uint256 invariantRatio)
    {
        uint256[] memory seedScaled18 = _toScaled18(_pool, _seedAmounts);
        uint256[] memory afterScaled18 = new uint256[](seedScaled18.length);
        uint256[] memory depositScaled18 = _toScaled18(_pool, _firstDepositAmounts);
        for (uint256 i = 0; i < seedScaled18.length; ++i) {
            afterScaled18[i] = seedScaled18[i] + depositScaled18[i];
        }

        // Mirror the Vault's rounding for an unbalanced add: current up, new down
        uint256 seedInvariant = IBasePool(_pool).computeInvariant(seedScaled18, Rounding.ROUND_UP);
        uint256 afterInvariant = IBasePool(_pool).computeInvariant(afterScaled18, Rounding.ROUND_DOWN);
        return (afterInvariant * 1e18) / seedInvariant;
    }

    /// @dev Reverts when the seed is too small for the first deposit to stay under the pool's growth cap
    function _requireSeedCarriesFirstDeposit(address _pool, uint256[] memory _seed, uint256[] memory _firstDeposit) internal view {
        uint256 ratio = previewFirstDepositInvariantRatio(_pool, _seed, _firstDeposit);
        require(ratio <= MAX_INVARIANT_RATIO, GENESIS_TOO_SMALL_FOR_FIRST_DEPOSIT(ratio, MAX_INVARIANT_RATIO));
    }

    /// @dev Scales raw token amounts the way the Vault does, by decimal scaling factor and token rate
    function _toScaled18(address _pool, uint256[] memory _rawAmounts) internal view returns (uint256[] memory scaled18) {
        (uint256[] memory decimalScalingFactors, uint256[] memory tokenRates) = BALANCER_V3_VAULT.getPoolTokenRates(_pool);
        scaled18 = new uint256[](_rawAmounts.length);
        for (uint256 i = 0; i < _rawAmounts.length; ++i) {
            scaled18[i] = (_rawAmounts[i] * decimalScalingFactors[i] * tokenRates[i]) / 1e18;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Routes a call to the Balancer Vault through the market authority, which is the address the pool records
     *      as its pause manager, so the Vault's pause manager check passes
     */
    function _callAsAuthority(bytes memory _data) internal {
        IAccessManager(ROYCO_FACTORY.ROYCO_AUTHORITY()).execute(address(BALANCER_V3_VAULT), _data);
    }

    /// @dev Reads the Balancer pool out of a template's deployment result extras
    function _poolOf(IRoycoProtocolTemplate.DeploymentResult memory _result) internal pure returns (address pool) {
        if (_result.extras.length < 32) return address(0);
        bytes memory extras = _result.extras;
        assembly ("memory-safe") {
            pool := mload(add(extras, 0x20))
        }
    }
}

/// @notice The single accountant setter this contract calls, declared locally so the periphery pulls in no more of
///         the accountant's surface than it uses
interface IRoycoDayAccountantLike {
    function setMinLiquidity(uint64 minLiquidityWAD) external;
}
