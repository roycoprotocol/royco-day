// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { CREATE3 } from "../../../lib/solady/src/utils/CREATE3.sol";
import { RoycoDayEntryPoint } from "../../../src/entrypoint/RoycoDayEntryPoint.sol";
import { RoycoCreate3Deployer } from "../../../src/factory/RoycoCreate3Deployer.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { TAG_ST_PROXY } from "../../../src/factory/templates/base/Constants.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { CREATE2_FACTORY_ADDRESS } from "../../utils/Create2DeployUtils.sol";

/**
 * @title RoycoDeterministic
 * @notice The single source of truth for every deterministic derivation the deployment pipeline relies on: singleton
 *         salts, the factory-proxy prediction, the periphery predictions, and the market-id mining derivation.
 */
library RoycoDeterministic {
    /// @notice The environment salt suffixes: a test deployment and a production deployment never collide on a deterministic address.
    string internal constant PROD_SALT_SUFFIX = "_PROD";
    string internal constant TEST_SALT_SUFFIX = "_TEST_3243241421";

    /// @notice CREATE2 salt for a protocol singleton (AccessManager, factory, template, etc.), suffixed by environment
    function singletonSalt(string memory _seed, bool _isTest) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_seed, _isTest ? TEST_SALT_SUFFIX : PROD_SALT_SUFFIX));
    }

    /// @notice CREATE2 address under the canonical deterministic deployer
    function create2Address(bytes32 _salt, bytes32 _initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY_ADDRESS, _salt, _initCodeHash)))));
    }

    /// @notice The protocol's CREATE3 deployer for the environment
    function predictCreate3Deployer(bool _isTest) internal pure returns (address) {
        return create2Address(singletonSalt("ROYCO_CREATE3_DEPLOYER", _isTest), keccak256(type(RoycoCreate3Deployer).creationCode));
    }

    /// @notice Predicts the factory proxy `_deployer` stands up under the environment's salts
    function predictFactoryProxy(address _deployer, bool _isTest) internal pure returns (address) {
        return
            CREATE3.predictDeterministicAddress(
                keccak256(abi.encode(_deployer, singletonSalt("ROYCO_FACTORY_PROXY", _isTest))), predictCreate3Deployer(_isTest)
            );
    }

    /// @dev The entry point initializes with no tranche configs: every market's flow through the factory at deployment
    function entryPointInitData() internal pure returns (bytes memory) {
        return abi.encodeCall(RoycoDayEntryPoint.initialize, (new address[](0), new IRoycoDayEntryPoint.TrancheConfig[](0)));
    }

    /// @dev The syncer initializes with no registered kernels: every market's kernel is registered at deployment
    function syncerInitData(address _accessManager) internal pure returns (bytes memory) {
        return abi.encodeCall(RoycoMarketSyncer.initialize, (_accessManager, new address[](0)));
    }

    /// @dev ERC1967 proxy creation code for a deterministic proxy deployment (mirrors Create2DeployUtils)
    function erc1967ProxyCreationCode(address _implementation, bytes memory _initData) internal pure returns (bytes memory) {
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(_implementation, _initData));
    }

    /// @notice Predicts both periphery singletons' CREATE2 addresses, which the gatekeeper is built against before either can be deployed
    function predictPeripherySingletons(
        address _accessManager,
        address _factory,
        bool _isTest
    )
        internal
        pure
        returns (address entryPoint, address marketSyncer)
    {
        address entryPointImpl = create2Address(
            singletonSalt("ROYCO_DAY_ENTRY_POINT_IMPLEMENTATION", _isTest),
            keccak256(abi.encodePacked(type(RoycoDayEntryPoint).creationCode, abi.encode(_factory)))
        );
        entryPoint =
            create2Address(singletonSalt("ROYCO_DAY_ENTRY_POINT_PROXY", _isTest), keccak256(erc1967ProxyCreationCode(entryPointImpl, entryPointInitData())));

        address syncerImpl = create2Address(singletonSalt("ROYCO_MARKET_SYNCER_IMPLEMENTATION", _isTest), keccak256(type(RoycoMarketSyncer).creationCode));
        marketSyncer = create2Address(
            singletonSalt("ROYCO_MARKET_SYNCER_PROXY", _isTest), keccak256(erc1967ProxyCreationCode(syncerImpl, syncerInitData(_accessManager)))
        );
    }

    /// @notice The market id SEED for `_marketName` against `_factory`, which the params builder mines on top of
    function marketIdSeed(string memory _marketName, address _factory) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes(_marketName), _factory));
    }

    /// @notice The senior-tranche CREATE3 proxy the template will land on for these exact params and deployer
    /// @dev Mirrors the template's derivation exactly: the whole params struct plus the deployer, then the ST tag
    function predictSeniorTranche(
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory _params,
        address _factory,
        address _deployer
    )
        internal
        pure
        returns (address)
    {
        bytes32 baseSalt = keccak256(abi.encode(_params, _deployer));
        return CREATE3.predictDeterministicAddress(keccak256(abi.encodePacked("ROYCO_MARKET_", baseSalt, TAG_ST_PROXY)), _factory);
    }

    /**
     * @notice Mines the lowest-nonce marketId (on top of `_seed`) whose senior-tranche proxy sorts below the quote
     *         asset, so the senior share registers as pool token0 — the ordering the deployment path asserts
     * @dev Mutates `_params.marketId` in memory as it searches and leaves the winning id in place
     */
    function mineMarketId(
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory _params,
        bytes32 _seed,
        address _factory,
        address _deployer
    )
        internal
        pure
        returns (bytes32 marketId)
    {
        for (uint64 nonce;; ++nonce) {
            marketId = keccak256(abi.encodePacked(_seed, nonce));
            _params.marketId = marketId;
            if (uint160(predictSeniorTranche(_params, _factory, _deployer)) < uint160(_params.quoteAsset)) return marketId;
        }
    }
}
