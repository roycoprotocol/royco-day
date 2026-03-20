// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title SyncerDeploymentConfig
 * @notice Single configuration contract for all syncer deployment parameters
 */
abstract contract SyncerDeploymentConfig {
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

    /// @dev Deployed using CREATE2 on each chain
    address internal constant ROYCO_FACTORY = 0x7cC6fB28eC7b5e7afC3cB3986141797ffc27253C;

    // ═══════════════════════════════════════════════════════════════════════════
    // SYNCER NAMES
    // ═══════════════════════════════════════════════════════════════════════════

    string public constant MAINNET_SYNCER = "MAINNET_SYNCER";
    string public constant AVALANCHE_SYNCER = "AVALANCHE_SYNCER";
    string public constant ARBITRUM_SYNCER = "ARBITRUM_SYNCER";

    // ═══════════════════════════════════════════════════════════════════════════
    // SYNCER CONFIG STRUCT
    // ═══════════════════════════════════════════════════════════════════════════

    struct SyncerConfig {
        uint256 chainId;
        address roycoFactory;
        address[] marketKernels;
        address[] syncOperators;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SYNCER CONFIG MAPPING
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(string syncerName => SyncerConfig) internal _syncerConfigs;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error SyncerConfigNotFound(string syncerName);
    error SyncerChainIdMismatch(string syncerName, uint256 expectedChainId, uint256 actualChainId);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeSyncerConfigs();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SYNCER CONFIG GETTER
    // ═══════════════════════════════════════════════════════════════════════════

    function getSyncerConfig(string memory syncerName) public view returns (SyncerConfig memory) {
        SyncerConfig memory config = _syncerConfigs[syncerName];
        if (config.roycoFactory == address(0)) {
            revert SyncerConfigNotFound(syncerName);
        }
        if (config.chainId != block.chainid) {
            revert SyncerChainIdMismatch(syncerName, config.chainId, block.chainid);
        }
        return config;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SYNCER CONFIG INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _initializeSyncerConfigs() internal {
        // ═══════════════════════════════════════════════════════════════════════════
        // MAINNET SYNCER CONFIG
        // ═══════════════════════════════════════════════════════════════════════════

        SyncerConfig storage config = _syncerConfigs[MAINNET_SYNCER];
        config.chainId = MAINNET;
        config.roycoFactory = ROYCO_FACTORY;

        // Market kernels to add to the syncer:
        // - Neutrl sNUSD
        config.marketKernels.push(0x0aE0978B868804929fd4C06B3B22D9197B8cd3c6);
        // - Tokemak autoUSD
        config.marketKernels.push(0x8748D1c21CC550B435487F473d9Aaf6C84dA46A6);
        // - Smokehouse USDC Morpho
        config.marketKernels.push(0x6dBdf6EBdF02F50ec6a7d6F782850996928176F9);
        // - Maple syrupUSDC
        config.marketKernels.push(0xde1Ce2cF64808e50d000F93058784270E412B3A4);

        // ═══════════════════════════════════════════════════════════════════════════
        // AVALANCHE SYNCER CONFIG
        // ═══════════════════════════════════════════════════════════════════════════

        config = _syncerConfigs[AVALANCHE_SYNCER];
        config.chainId = AVALANCHE;
        config.roycoFactory = ROYCO_FACTORY;

        // Market kernels to add to the syncer:
        // - Avant savUSD
        config.marketKernels.push(0x7240FF91b471217FF93349184ABE9f102Ca1955C);

        // ═══════════════════════════════════════════════════════════════════════════
        // ARBITRUM SYNCER CONFIG
        // ═══════════════════════════════════════════════════════════════════════════

        config = _syncerConfigs[ARBITRUM_SYNCER];
        config.chainId = ARBITRUM;
        config.roycoFactory = ROYCO_FACTORY;

        // Market kernels to add to the syncer:
        // - Metastreet sUSDai
        config.marketKernels.push(0xFdb17E53eA5d342124b8473188BCB9F05F1949CA);
    }
}
