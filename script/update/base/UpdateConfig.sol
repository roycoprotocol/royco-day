// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";

/**
 * @title UpdateConfig
 * @notice Registry mapping market names to deployed kernel addresses per chain
 * @dev All other addresses (accountant, tranches) are derived from the kernel at runtime.
 *      Add new markets by extending `_initializeDeployedMarkets()`.
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
    // FACTORY ADDRESS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The Day factory (CREATE2 — same address on every chain).
    /// @dev TODO: set the deployed Day factory address once the first Day market is live.
    address internal constant ROYCO_FACTORY = address(0);

    /// @dev The Day entry point proxy (CREATE3 — same address on every chain).
    /// @dev TODO: set the deployed Day entry point address once the market deployment script (Deploy.s.sol) has run.
    address internal constant ROYCO_ENTRY_POINT = address(0);

    // ═══════════════════════════════════════════════════════════════════════════
    // MULTISIG ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Root multisig — holds the timelocked admin roles (ADMIN_ACCOUNTANT_ROLE, ADMIN_KERNEL_ROLE, etc.)
    address internal constant ROOT_MULTISIG = 0x7c405bbD131e42af506d14e752f2e59B19D49997;

    /// @dev Executor multisig — holds the GUARDIAN_ROLE (can cancel pending operations)
    address internal constant EXECUTOR_MULTISIG = 0x84d37A25e46029CE161111420E07cEb78880119e;

    /// @dev WCE multisig — operations multisig holding immediate-delay admin roles
    ///      (e.g. ADMIN_ENTRY_POINT_ROLE with 0 delay).
    address internal constant WCE_MULTISIG = 0x84d37A25e46029CE161111420E07cEb78880119e;

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET NAMES
    // ═══════════════════════════════════════════════════════════════════════════

    // Add Day market names here as they ship (e.g. `string internal constant SNUSD = "snUSD";`).

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Resolved market addresses (derived from kernel at runtime)
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

    /// @dev Chainlink-style aggregators (`latestRoundData()`) that need to stay "fresh" through the
    ///      2-day simulation warp. The harness captures `latestRoundData` for each entry pre-warp,
    ///      then `vm.mockCall`s the oracle post-warp to keep the same `answer` but report
    ///      `updatedAt = block.timestamp`, defeating downstream staleness checks.
    mapping(uint256 chainId => address[] oracles) internal _chainlinkOracles;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error MarketNotFound(string marketName, uint256 chainId);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeDeployedMarkets();
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
        addrs.accountant = kernel.ACCOUNTANT();
        addrs.seniorTranche = kernel.SENIOR_TRANCHE();
        addrs.juniorTranche = kernel.JUNIOR_TRANCHE();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _initializeDeployedMarkets() internal {
        // Register deployed Day markets here as they ship, e.g.:
        //   _deployedKernels[MAINNET][SNUSD] = 0x...;
        // and push any Chainlink/RedStone aggregators that must stay fresh through the 2-day simulation warp:
        //   _chainlinkOracles[MAINNET].push(0x...);
    }
}
