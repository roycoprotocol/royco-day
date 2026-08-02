// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { CREATE3 } from "../../../lib/solady/src/utils/CREATE3.sol";
import { RoycoCreate3Deployer } from "../../../src/factory/RoycoCreate3Deployer.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";

/// @dev Minimal payable-constructor contract so value forwarding through the deployer is observable
contract ValueHolder {
    constructor() payable { }
}

/**
 * @title Test_RoycoCreate3Deployer
 * @notice Pins the CREATE3 deployer the whole deterministic-address scheme hangs off: an address depends on the
 *         (caller, salt) pair alone and never on the creation code, salts are namespaced per caller so nobody can
 *         front-run another deployer's address space, and a claimed address can never be re-deployed
 */
contract Test_RoycoCreate3Deployer is Test {
    RoycoCreate3Deployer internal create3Deployer;

    address internal DEPLOYER_ALPHA = makeAddr("DEPLOYER_ALPHA");
    address internal DEPLOYER_BETA = makeAddr("DEPLOYER_BETA");

    bytes32 internal constant SHARED_SALT = keccak256("SHARED_SALT");

    /// @dev Mirror of the deployer's event for expectEmit
    event Deployed(address indexed deployed, address indexed deployer, bytes32 salt);

    function setUp() public {
        create3Deployer = new RoycoCreate3Deployer();
        vm.deal(DEPLOYER_ALPHA, 10 ether);
        vm.deal(DEPLOYER_BETA, 10 ether);
    }

    function _tokenCreationCode() internal pure returns (bytes memory) {
        return abi.encodePacked(type(MockERC20C).creationCode, abi.encode("Deployed Token", "DPLY", uint8(18)));
    }

    /// @notice deploy lands exactly on the address predict resolves for the caller's salt, independent of code
    function test_Deploy_LandsOnThePredictedAddress_AndEmits() public {
        address predicted = create3Deployer.predict(DEPLOYER_ALPHA, SHARED_SALT);
        assertEq(predicted.code.length, 0, "the predicted address must start empty");

        vm.expectEmit(true, true, false, true, address(create3Deployer));
        emit Deployed(predicted, DEPLOYER_ALPHA, SHARED_SALT);
        vm.prank(DEPLOYER_ALPHA);
        address deployed = create3Deployer.deploy(SHARED_SALT, _tokenCreationCode());

        assertEq(deployed, predicted, "the deployment must occupy the predicted address");
        assertGt(deployed.code.length, 0, "the deployed contract must be live");
        assertEq(MockERC20C(deployed).decimals(), 18, "the constructor arguments must have been applied");
    }

    /// @notice Salts are namespaced to the caller: the same salt resolves a DIFFERENT address per deployer, and both
    ///         deployers can claim their own address, so one deployer can never front-run another's salt
    function test_Deploy_SaltsAreNamespacedPerCaller() public {
        address predictedForAlpha = create3Deployer.predict(DEPLOYER_ALPHA, SHARED_SALT);
        address predictedForBeta = create3Deployer.predict(DEPLOYER_BETA, SHARED_SALT);
        assertTrue(predictedForAlpha != predictedForBeta, "the same salt must resolve distinct addresses per caller");

        vm.prank(DEPLOYER_ALPHA);
        address deployedByAlpha = create3Deployer.deploy(SHARED_SALT, _tokenCreationCode());
        vm.prank(DEPLOYER_BETA);
        address deployedByBeta = create3Deployer.deploy(SHARED_SALT, _tokenCreationCode());

        assertEq(deployedByAlpha, predictedForAlpha, "alpha claims alpha's address");
        assertEq(deployedByBeta, predictedForBeta, "beta claims beta's address despite the shared salt");
    }

    /// @notice The prediction is code-independent: two different creation codes under the same (caller, salt) resolve
    ///         the same address, which is the property that lets the factory address precede the factory
    function test_Predict_IsIndependentOfCreationCode() public {
        address predicted = create3Deployer.predict(DEPLOYER_ALPHA, SHARED_SALT);
        vm.prank(DEPLOYER_ALPHA);
        address deployed = create3Deployer.deploy(SHARED_SALT, abi.encodePacked(type(ValueHolder).creationCode));
        assertEq(deployed, predicted, "a different creation code must still land on the salt-derived address");
    }

    /// @notice A (caller, salt) pair is single-use: the address is occupied forever after the first deployment
    function test_RevertIf_SameCallerRedeploysTheSameSalt() public {
        vm.prank(DEPLOYER_ALPHA);
        create3Deployer.deploy(SHARED_SALT, _tokenCreationCode());
        vm.prank(DEPLOYER_ALPHA);
        vm.expectRevert(CREATE3.DeploymentFailed.selector);
        create3Deployer.deploy(SHARED_SALT, _tokenCreationCode());
    }

    /// @notice Value sent with deploy is forwarded into the constructor
    function test_Deploy_ForwardsValueToTheConstructor() public {
        vm.prank(DEPLOYER_ALPHA);
        address deployed = create3Deployer.deploy{ value: 1 ether }(SHARED_SALT, abi.encodePacked(type(ValueHolder).creationCode));
        assertEq(deployed.balance, 1 ether, "the deployment value must land on the deployed contract");
    }
}
