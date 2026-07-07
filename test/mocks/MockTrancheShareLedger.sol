// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title MockTrancheShareLedger
 * @notice Minimal tranche share ledger: a settable total supply plus recording mint entrypoints matching the
 *         IRoycoSeniorTranche.mintLiquidityPremiumShares / IRoycoVaultTranche.mintProtocolFeeShares surface
 * @dev Fidelity gaps vs a real tranche: no per-account balances, no auth (production mints are kernel-only),
 *      and no Transfer events, it only records the last call and grows the supply so FeeAndLiquidityPremiumLogic
 *      tests can assert exact mint arguments and ordering
 */
contract MockTrancheShareLedger {
    uint256 public totalSupply;

    uint256 public premiumMintCallCount;
    address public lastPremiumMintTo;
    uint256 public lastPremiumSharesMinted;

    uint256 public feeMintCallCount;
    address public lastFeeMintTo;
    uint256 public lastFeeSharesMinted;

    function setTotalSupply(uint256 _totalSupply) external {
        totalSupply = _totalSupply;
    }

    /// @dev Mirror of IRoycoSeniorTranche.mintLiquidityPremiumShares, recording the call and growing the supply
    function mintLiquidityPremiumShares(address _to, uint256 _liquidityPremiumShares) external returns (uint256 totalTrancheShares) {
        premiumMintCallCount++;
        lastPremiumMintTo = _to;
        lastPremiumSharesMinted = _liquidityPremiumShares;
        totalSupply += _liquidityPremiumShares;
        return totalSupply;
    }

    /// @dev Mirror of IRoycoVaultTranche.mintProtocolFeeShares, recording the call and growing the supply
    function mintProtocolFeeShares(address _protocolFeeRecipient, uint256 _protocolFeeShares) external returns (uint256 totalTrancheShares) {
        feeMintCallCount++;
        lastFeeMintTo = _protocolFeeRecipient;
        lastFeeSharesMinted = _protocolFeeShares;
        totalSupply += _protocolFeeShares;
        return totalSupply;
    }
}
