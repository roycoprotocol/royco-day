// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title MockRoycoFactory
 * @notice Minimal stand-in for the Royco factory's entry-point-facing surface: the ROYCO_AUTHORITY getter and the
 *         trancheToKernel provenance registry (zero for unknown addresses, mirroring IRoycoFactory's semantics)
 * @dev DayMarketTestBase deploys markets without the real factory, so entry point suites register the fixture's
 *      tranches here to satisfy RoycoDayEntryPoint's provenance validation
 */
contract MockRoycoFactory {
    /// @notice Thrown when a factory-forwarded call reverts (mirrors IRoycoFactory.FACTORY_CALL_FAILED)
    error FACTORY_CALL_FAILED(bytes returnData);

    /// @notice The AccessManager that governs this factory and its markets
    address public immutable ROYCO_AUTHORITY;

    /// @notice Returns the kernel a factory-deployed tranche belongs to (zero for unknown addresses)
    mapping(address tranche => address kernel) public trancheToKernel;

    constructor(address _roycoAuthority) {
        ROYCO_AUTHORITY = _roycoAuthority;
    }

    /// @notice Registers a tranche as factory-deployed by mapping it to its market's kernel
    function setTrancheKernel(address _tranche, address _kernel) external {
        trancheToKernel[_tranche] = _kernel;
    }

    /// @notice Forwards an arbitrary call as the factory (test stand-in for the production executeAsFactory,
    ///         without the active-template gate): entry point suites route initial tranche configuration through
    ///         this, mirroring how production templates configure the entry point during market deployments
    function executeAsFactory(address _target, bytes calldata _data) external returns (bytes memory result) {
        bool success;
        (success, result) = _target.call(_data);
        require(success, FACTORY_CALL_FAILED(result));
    }
}
