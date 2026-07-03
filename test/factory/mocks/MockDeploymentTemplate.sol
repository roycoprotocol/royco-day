// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IBaseTemplate } from "../../../src/interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";

/// @notice A trivial, parameterless contract the mock template CREATE3-deploys via the factory to exercise the
///         `deployDeterministicContract` primitive during an active deployment window. Parameterless so
///         `type(Dummy).creationCode` deploys without appended constructor args.
contract Dummy {
    uint256 public constant tag = 42;
}

/// @notice A minimal UUPS-free implementation with a no-op `initialize`, used behind an ERC1967 proxy to
///         exercise `deployDeterministicProxy` (OZ mandates non-empty init data in the proxy constructor).
contract InitTarget {
    uint256 public x;

    function initialize() external {
        x = 1;
    }
}

/// @notice Records the caller of `ping()` so a test can assert `executeAsFactory` forwards calls AS the factory.
///         `boom()` always reverts, to exercise the factory's `FACTORY_CALL_FAILED` propagation.
contract CallRecorder {
    address public lastCaller;
    uint256 public pings;

    function ping() external returns (uint256) {
        lastCaller = msg.sender;
        pings++;
        return pings;
    }

    function boom() external pure {
        revert("boom");
    }
}

/// @title MockDeploymentTemplate
/// @notice A configurable `IBaseTemplate` used to unit-test `RoycoFactory` in isolation from any real market recipe.
/// @dev The factory drives a template through `initialize` (at registration), then `deployMarket` + `verify`
///      (inside `executeMarketDeployment`). This mock lets a test pre-configure what `deployMarket` returns and
///      which factory primitive it exercises while the deployment window is open, so the factory's own logic
///      (active-template binding, mapping storage, verify-revert propagation, reentrancy guard) can be asserted
///      without standing up tranches/kernels/accountants.
contract MockDeploymentTemplate is IBaseTemplate {
    /// @dev Which active-window primitive `deployMarket` should exercise.
    enum Primitive {
        None,
        DeployContract,
        DeployProxy,
        SetTargetFunctionRole,
        GrantRole,
        ExecuteAsFactory,
        DeployContractTwiceSameSalt,
        ReenterExecuteMarketDeployment
    }

    /// @inheritdoc IBaseTemplate
    IRoycoFactory public immutable override(IBaseTemplate) ROYCO_FACTORY;

    // ─── Registration bookkeeping ───
    bool public initialized;
    uint256 public initializeCallCount;

    // ─── Configurable deploy output ───
    address public seniorTrancheOut;
    address public juniorTrancheOut;
    address public liquidityTrancheOut;

    // ─── Behavior toggles (set by the test before triggering executeMarketDeployment) ───
    bool public revertOnDeploy;
    bool public revertOnVerify;
    bool public revertOnValidateParams;
    Primitive public primitive;

    // ─── Primitive parameters / observed results ───
    bytes32 public salt;
    address public roleTarget; // for SetTargetFunctionRole / GrantRole / ExecuteAsFactory
    bytes4 public roleSelector;
    uint64 public roleId;
    address public roleAccount;
    address public lastDeployedContract;
    address public lastDeployedProxy;
    bool public lastAlreadyDeployed;
    bytes public lastExecuteAsFactoryReturn;

    constructor(IRoycoFactory _factory) {
        ROYCO_FACTORY = _factory;
    }

    // ─── Test configuration setters ───

    function setDeployResult(address _senior, address _junior, address _liquidity) external {
        seniorTrancheOut = _senior;
        juniorTrancheOut = _junior;
        liquidityTrancheOut = _liquidity;
    }

    function setRevertOnDeploy(bool _v) external {
        revertOnDeploy = _v;
    }

    function setRevertOnVerify(bool _v) external {
        revertOnVerify = _v;
    }

    function setRevertOnValidateParams(bool _v) external {
        revertOnValidateParams = _v;
    }

    function setPrimitive(Primitive _p, bytes32 _salt) external {
        primitive = _p;
        salt = _salt;
    }

    function setRoleWiring(address _target, bytes4 _selector, uint64 _roleId, address _account) external {
        roleTarget = _target;
        roleSelector = _selector;
        roleId = _roleId;
        roleAccount = _account;
    }

    // ─── IRoycoProtocolTemplate ───

    /// @inheritdoc IRoycoProtocolTemplate
    function initialize(bytes32[] calldata, bytes[] calldata) external override(IRoycoProtocolTemplate) {
        require(msg.sender == address(ROYCO_FACTORY), ONLY_ROYCO_FACTORY());
        initialized = true;
        initializeCallCount++;
    }

    /// @inheritdoc IBaseTemplate
    function bytecodePointer(bytes32) external pure override(IBaseTemplate) returns (address) {
        return address(0);
    }

    /// @inheritdoc IRoycoProtocolTemplate
    function validateParams(bytes calldata) external view override(IRoycoProtocolTemplate) {
        if (revertOnValidateParams) revert INVALID_PARAMS();
    }

    /// @inheritdoc IRoycoProtocolTemplate
    function deployMarket(bytes calldata) external override(IRoycoProtocolTemplate) returns (DeploymentResult memory result) {
        require(msg.sender == address(ROYCO_FACTORY), ONLY_ROYCO_FACTORY());
        if (revertOnDeploy) revert INVALID_PARAMS();

        _exercisePrimitive();

        result.seniorTranche = seniorTrancheOut;
        result.juniorTranche = juniorTrancheOut;
        result.liquidityTranche = liquidityTrancheOut;
    }

    /// @inheritdoc IRoycoProtocolTemplate
    function verify(DeploymentResult calldata) external view override(IRoycoProtocolTemplate) {
        if (revertOnVerify) revert INVALID_PARAMS();
    }

    // ─── Internal: active-window primitive exercise ───

    function _exercisePrimitive() internal {
        if (primitive == Primitive.None) return;

        if (primitive == Primitive.DeployContract) {
            (lastDeployedContract, lastAlreadyDeployed) = ROYCO_FACTORY.deployDeterministicContract(type(Dummy).creationCode, salt);
        } else if (primitive == Primitive.DeployContractTwiceSameSalt) {
            ROYCO_FACTORY.deployDeterministicContract(type(Dummy).creationCode, salt);
            // Second call with the same salt must report alreadyDeployed and NOT redeploy.
            (lastDeployedContract, lastAlreadyDeployed) = ROYCO_FACTORY.deployDeterministicContract(type(Dummy).creationCode, salt);
        } else if (primitive == Primitive.DeployProxy) {
            // Point the proxy at an initializable implementation with valid (non-empty) init data.
            address impl = address(new InitTarget());
            (lastDeployedProxy, lastAlreadyDeployed) =
                ROYCO_FACTORY.deployDeterministicProxy(impl, abi.encodeCall(InitTarget.initialize, ()), salt);
        } else if (primitive == Primitive.SetTargetFunctionRole) {
            ROYCO_FACTORY.setMarketTargetFunctionRole(roleTarget, roleSelector, roleId);
        } else if (primitive == Primitive.GrantRole) {
            ROYCO_FACTORY.grantMarketRole(roleId, roleAccount, 0);
        } else if (primitive == Primitive.ExecuteAsFactory) {
            lastExecuteAsFactoryReturn = ROYCO_FACTORY.executeAsFactory(roleTarget, abi.encodeWithSelector(roleSelector));
        } else if (primitive == Primitive.ReenterExecuteMarketDeployment) {
            // Re-enter the factory's deployment entrypoint; expected to revert with NO_ACTIVE_TEMPLATE.
            ROYCO_FACTORY.executeMarketDeployment(address(this), "");
        }
    }
}
