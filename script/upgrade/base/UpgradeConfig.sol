// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title UpgradeConfig
 * @notice Self-contained registry of deployed Royco addresses for the upgrade system.
 * @dev Holds every address the upgrade scripts need — factory, multisigs, and per-market
 *      (ST / JT / accountant / kernel). Unlike the parameter-update config, this does not
 *      derive ST/JT/accountant from the kernel via on-chain calls; everything is hardcoded so
 *      upgrades never depend on the current live contracts being intact (e.g. when the kernel
 *      itself is the thing being upgraded). YDM is omitted — it is non-upgradeable.
 *
 *      Add new markets or chains by extending `_initializeConfig()` — strictly additive; never
 *      mutate existing entries without a code review.
 */
abstract contract UpgradeConfig {
    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN IDs
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 internal constant MAINNET = 1;
    uint256 internal constant AVALANCHE = 43_114;
    uint256 internal constant ARBITRUM = 42_161;
    uint256 internal constant BASE = 8453;

    // ═══════════════════════════════════════════════════════════════════════════
    // MULTISIGS  (same across every chain)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Holds the timelocked admin roles including `ADMIN_UPGRADER_ROLE`
    address internal constant ROOT_MULTISIG = 0x7c405bbD131e42af506d14e752f2e59B19D49997;

    /// @dev Holds `GUARDIAN_ROLE` (can cancel pending operations)
    address internal constant EXECUTOR_MULTISIG = 0x84d37A25e46029CE161111420E07cEb78880119e;

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET NAMES
    // ═══════════════════════════════════════════════════════════════════════════

    // Add Day market names here as they ship (e.g. `string internal constant SNUSD = "snUSD";`).

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    struct MarketAddresses {
        address seniorTranche;
        address juniorTranche;
        address accountant;
        address kernel;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error UpgradeConfig__FactoryNotRegistered(uint256 chainId);
    error UpgradeConfig__MarketNotFound(string marketName, uint256 chainId);

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Factory (AccessManager) per chain. A singleton — one factory deployment per chain,
    ///      not keyed per market. Every market on a given chain shares this factory.
    mapping(uint256 chainId => address factory) internal _factories;

    /// @dev (chainId, marketName) → addresses for the market's ST, JT, accountant, and kernel
    mapping(uint256 chainId => mapping(string marketName => MarketAddresses addrs)) internal _markets;

    /// @dev Chainlink-style aggregators (anything implementing `latestRoundData()`) that need to
    ///      stay "fresh" through the 2-day simulation warp. Before the warp the orchestrator
    ///      captures `latestRoundData` for each entry and after the warp it `vm.mockCall`s the
    ///      oracle so the response keeps its `answer` but reports `updatedAt = block.timestamp`,
    ///      avoiding staleness reverts in downstream sync/pricing math.
    mapping(uint256 chainId => address[] oracles) internal _chainlinkOracles;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeConfig();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GETTERS
    // ═══════════════════════════════════════════════════════════════════════════

    function getFactory(uint256 _chainId) public view returns (address factory) {
        factory = _factories[_chainId];
        require(factory != address(0), UpgradeConfig__FactoryNotRegistered(_chainId));
    }

    function getMarketAddresses(uint256 _chainId, string memory _marketName) public view returns (MarketAddresses memory addrs) {
        addrs = _markets[_chainId][_marketName];
        require(addrs.kernel != address(0), UpgradeConfig__MarketNotFound(_marketName, _chainId));
    }

    function getChainlinkOracles(uint256 _chainId) public view returns (address[] memory oracles) {
        oracles = _chainlinkOracles[_chainId];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _initializeConfig() internal virtual {
        // Register the deployed Day factory + markets here as they ship, e.g.:
        //   _factories[MAINNET] = 0x...; // the Day factory (CREATE2 — same address on every chain)
        //   _markets[MAINNET][SNUSD] = MarketAddresses({ seniorTranche: 0x..., juniorTranche: 0x..., accountant: 0x..., kernel: 0x... });
        // and push any Chainlink/RedStone aggregators that must stay fresh through the 2-day simulation warp:
        //   _chainlinkOracles[MAINNET].push(0x...);
    }
}
