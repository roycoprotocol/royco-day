// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_BALANCER_POOL_MANAGER_ROLE,
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE,
    ADMIN_FACTORY_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_MARKET_OPS_ROLE,
    ADMIN_ORACLE_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    GUARDIAN_ROLE,
    LP_ROLE_ADMIN_ROLE
} from "../../../src/factory/Roles.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";

/**
 * @title UpdateConfig
 * @notice Shared address registry for the parameter-update scripts: the chain-agnostic protocol singletons, the
 *         governance multisigs (the kerchkoffs four-multisig model), the role -> scheduler mapping every update
 *         resolves its Safe submitter through, and the per-chain deployed-kernel registry markets are looked up in.
 * @dev The AccessManager, factory, and entry point are CREATE2/CREATE3 with no chain-specific input, so their
 *      addresses are identical on every chain for the prod deployer. Market kernels differ per chain and are
 *      registered in `_initializeDeployedMarkets()` as they ship.
 */
abstract contract UpdateConfig {
    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN IDs
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 internal constant MAINNET = 1;
    uint256 internal constant AVALANCHE = 43_114;
    uint256 internal constant ARBITRUM = 42_161;
    uint256 internal constant BASE = 8453;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL SINGLETONS (chain-agnostic — same address on every chain)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The RoycoAccessManager — the target of every schedule/execute/cancel transaction (_PROD_V1.0.2)
    address internal constant ACCESS_MANAGER = 0x82EecE4a736db0767370d2DfFdE9BDF6e38AaeB8;

    /// @dev The Day factory proxy (CREATE3 vanity address, _PROD_V1.0.2)
    address internal constant ROYCO_FACTORY = 0xaAAaaAAAaE46cA12Bf3810DF8C13c5E8A4400812;

    /// @dev The Day entry point proxy (_PROD_V1.0.2)
    address internal constant ROYCO_ENTRY_POINT = 0xaF55a0c251690d9322b5F94b7e50EE895750262c;

    /// @notice The registered Day template per chain (_PROD_V1.0.2)
    /// @dev Unlike the singletons above, the template's CREATE2 constructor args include the chain's Balancer venue
    ///      factories, so its address DIFFERS per chain (captured from each chain's bootstrap broadcast).
    function dayTemplate(uint256 _chainId) internal pure returns (address) {
        if (_chainId == MAINNET) return 0xDA3fd0EFF34f201436F21806A0F2A0B55A5b97f1;
        if (_chainId == ARBITRUM) return 0x281EaB0FFC407F17BdFC5964984490DF58F3A25d;
        if (_chainId == BASE) return 0x51b1000A0eF7199d2D37Ee1Bb70bB9118D65F3DB;
        if (_chainId == AVALANCHE) return 0x6a5F3284E6b1882061D80339602A6c0eA36D0594;
        revert("no Day template configured for this chain");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GOVERNANCE MULTISIGS (kerchkoffs four-multisig model)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev FNDN — super-admin; unpauser; entry-point fee collection; guardian + emergency-oracle co-hold
    address internal constant FNDN = 0x7c405bbD131e42af506d14e752f2e59B19D49997;

    /// @dev WAY — holds every parameter-update role, scheduling all delayed ops
    address internal constant WAY = 0x84d37A25e46029CE161111420E07cEb78880119e;

    /// @dev WAY_PAUSE — sole pauser (immediate)
    address internal constant WAY_PAUSE = 0xC7605B1891B449B0051d55D083B49D6b46D164bb;

    /// @dev FNDN_VETO — guardian co-hold (immediate)
    address internal constant FNDN_VETO = 0xc5Df006FA0647EFF1A55CCF5749ce17772F4d8CB;

    /// @dev AUTO — LP-role-admin co-hold (immediate)
    address internal constant AUTO = 0xb2B80EBcb7EE285806ddcB26E84a444032D1c244;

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Resolved market addresses (derived from the kernel at runtime)
    struct MarketAddresses {
        address kernel;
        address accountant;
        address seniorTranche;
        address juniorTranche;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev chainId → marketName → kernel address
    mapping(uint256 chainId => mapping(string marketName => address kernel)) internal _deployedKernels;

    /// @dev Chainlink-style aggregators (`latestRoundData()`) kept "fresh" across the simulation warp (see
    ///      `ParameterUpdateBase._simulate`): captured pre-warp, re-mocked post-warp with `updatedAt = block.timestamp`.
    mapping(uint256 chainId => address[] oracles) internal _chainlinkOracles;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error MarketNotFound(string marketName, uint256 chainId);
    error UnknownRoleScheduler(uint64 roleId);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeDeployedMarkets();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLE → SCHEDULER RESOLUTION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice The multisig that submits (schedules + executes, or directly calls) an operation gated by `_roleId`.
     * @dev Mirrors the kerchkoffs role distribution. The base reads the HOLDER'S execution delay from the live
     *      AccessManager to decide whether the op is a direct call (0 delay) or a schedule/execute (non-zero delay),
     *      so this map only needs the holder, not the delay.
     */
    function _roleScheduler(uint64 _roleId) internal pure returns (address scheduler) {
        if (_roleId == ADMIN_ROLE) return FNDN;
        if (_roleId == ADMIN_PAUSER_ROLE) return WAY_PAUSE;
        if (_roleId == ADMIN_UNPAUSER_ROLE) return FNDN;
        if (_roleId == ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE) return FNDN;
        if (_roleId == GUARDIAN_ROLE) return FNDN;
        if (
            _roleId == ADMIN_UPGRADER_ROLE || _roleId == ADMIN_KERNEL_ROLE || _roleId == ADMIN_ACCOUNTANT_ROLE || _roleId == ADMIN_PROTOCOL_FEE_SETTER_ROLE
                || _roleId == ADMIN_ORACLE_ROLE || _roleId == ADMIN_MARKET_OPS_ROLE || _roleId == ADMIN_BALANCER_POOL_MANAGER_ROLE
                || _roleId == ADMIN_ENTRY_POINT_ROLE || _roleId == LP_ROLE_ADMIN_ROLE || _roleId == ADMIN_FACTORY_ROLE
        ) {
            return WAY;
        }
        revert UnknownRoleScheduler(_roleId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GETTERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the Chainlink-style oracles to keep fresh during simulation for `_chainId`.
    function getChainlinkOracles(uint256 _chainId) public view returns (address[] memory oracles) {
        oracles = _chainlinkOracles[_chainId];
    }

    /**
     * @notice Resolves all market addresses from the kernel for the current chain
     * @param _marketName The market name (must match a configured entry)
     * @return addrs The resolved kernel, accountant, and tranche addresses
     */
    function getMarketAddresses(string memory _marketName) public view returns (MarketAddresses memory addrs) {
        addrs.kernel = _deployedKernels[block.chainid][_marketName];
        require(addrs.kernel != address(0), MarketNotFound(_marketName, block.chainid));

        IRoycoDayKernel kernel = IRoycoDayKernel(addrs.kernel);
        addrs.accountant = kernel.accountant();
        addrs.seniorTranche = kernel.seniorTranche();
        addrs.juniorTranche = kernel.juniorTranche();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _initializeDeployedMarkets() internal {
        // Register deployed Day markets here as they ship, e.g.:
        //   _deployedKernels[MAINNET][SNUSD] = 0x...;
        // and push any Chainlink/RedStone aggregators that must stay fresh through the simulation warp:
        //   _chainlinkOracles[MAINNET].push(0x...);
    }
}
