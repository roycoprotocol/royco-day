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
}
