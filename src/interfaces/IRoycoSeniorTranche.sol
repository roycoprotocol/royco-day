// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoVaultTranche } from "./IRoycoVaultTranche.sol";

/**
 * @title IRoycoSeniorTranche
 * @notice Interface for the senior tranche (ST): the standard share-token surface (inherited from IRoycoVaultTranche) plus
 *         the senior-specific liquidity premium share mint, by which the kernel routes senior yield to the liquidity tranche
 *         as newly minted senior shares
 * @dev Only the senior tranche carries this mint: the liquidity premium is a reassignment of senior appreciation, so it is
 *      paid as senior shares. The junior and liquidity tranches share the base IRoycoVaultTranche surface without it
 */
interface IRoycoSeniorTranche is IRoycoVaultTranche {
    /**
     * @notice Emitted when liquidity premium shares are minted to the kernel on behalf of the liquidity tranche
     * @param holder The address that received the minted premium shares (the kernel, which custodies them for the liquidity tranche)
     * @param mintedLiquidityPremiumShares The number of senior shares minted as the liquidity premium
     * @param totalTrancheShares The total shares in the senior tranche after minting the liquidity premium shares
     */
    event LiquidityPremiumSharesMinted(address indexed holder, uint256 mintedLiquidityPremiumShares, uint256 totalTrancheShares);

    /**
     * @notice Mints a kernel-computed number of liquidity premium shares to the specified holder
     * @dev Only callable by the kernel during accounting synchronization
     * @dev The liquidity premium is senior yield routed to the liquidity tranche, minted as senior tranche shares held by
     *      the kernel on the LT's behalf. This leaves the senior raw NAV (and thus coverage) unchanged, so the mint is
     *      coverage-neutral and only reassigns senior appreciation to the LT
     * @dev Takes a precomputed share count, priced jointly with the ST protocol fee so neither carve-out dilutes the other
     * @param _to The account to mint the premium shares to (the kernel, which custodies them for the liquidity tranche)
     * @param _liquidityPremiumShares The precomputed number of liquidity premium shares to mint
     * @return totalTrancheShares The total shares in the senior tranche after minting the liquidity premium shares
     */
    function mintLiquidityPremiumShares(address _to, uint256 _liquidityPremiumShares) external returns (uint256 totalTrancheShares);
}
