// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC20PermitUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { JT_LP_ROLE, LT_LP_ROLE, ST_LP_ROLE } from "../../../src/factory/Roles.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_TranchePermit_Tranches
 * @notice Exercises the EIP-2612 permit surface of all three tranche share tokens: a gasless signature must set an
 *         allowance a delegate can redeem through, the EIP's replay and expiry rules must hold, and pausing a
 *         tranche must gate asset movement but never signature approvals
 * @dev Every permit digest below is assembled from the EIP-712 and EIP-2612 constants (domain typehash, tranche
 *      name, version "1", chain id, tranche proxy address) rather than read from the tranche's DOMAIN_SEPARATOR,
 *      so a mis-wired domain in the tranche would fail these signatures instead of being mirrored by them.
 *      Seeded once in setUp so every payout literal is against the same wei-exact state: ST 100e18 and JT 30e18
 *      vault shares (coverage (100 + 30) x 0.2 / 30 = 0.8667 <= 1) plus the base's auto-seeded quote-only LT depth
 *      of 6e18 BPT at a NAV-per-BPT of exactly 1.0, with all rates at 1.0 and no PnL so no fee or premium shares
 *      ever perturb the supplies
 */
contract Test_TranchePermit_Tranches is DayMarketTestBase {
    /// @dev keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)") per EIP-712
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)") per EIP-2612
    bytes32 internal constant PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /// @dev The share owner whose private key signs every permit below
    address internal PERMIT_OWNER;

    /// @dev The signing key backing PERMIT_OWNER
    uint256 internal PERMIT_OWNER_KEY;

    /// @dev Per-tranche delegates holding the LP role each tranche's redeem gate requires
    address internal ST_DELEGATE;
    address internal JT_DELEGATE;
    address internal LT_DELEGATE;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        _seedMarket(100e18, 30e18);
        (PERMIT_OWNER, PERMIT_OWNER_KEY) = makeAddrAndKey("PERMIT_OWNER");
        ST_DELEGATE = _generateActor("ST_DELEGATE", ST_LP_ROLE);
        JT_DELEGATE = _generateActor("JT_DELEGATE", JT_LP_ROLE);
        LT_DELEGATE = _generateActor("LT_DELEGATE", LT_LP_ROLE);
    }

    /**
     * @notice Builds an EIP-2612 permit digest from first principles for one of this market's tranche tokens
     * @dev The domain separator is hand-assembled from the tranche's ERC-20 name, the OZ permit version "1", the
     *      live chain id, and the tranche proxy address, and the struct hash follows the EIP's Permit member order,
     *      so the resulting digest is what ANY correct EIP-2612 verifier must accept, independent of the tranche
     */
    function _permitDigest(
        address _tranche,
        string memory _trancheName,
        address _spender,
        uint256 _value,
        uint256 _nonce,
        uint256 _deadline
    )
        internal
        view
        returns (bytes32 digest)
    {
        bytes32 domainSeparator = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256(bytes(_trancheName)), keccak256(bytes("1")), block.chainid, _tranche));
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, PERMIT_OWNER, _spender, _value, _nonce, _deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /**
     * @notice A permit signature sets the delegate's allowance and advances the owner's nonce on every tranche, and
     *         the delegate then redeems the owner's shares with the assets landing at the receiver
     * @dev The permit-then-redeem pair is the gasless-onboarding path for every tranche share (the owner never
     *      sends a transaction), so it is proven on ST, JT, and LT in one run. Payouts at the seeded 1.0 rates,
     *      scaled by the virtual-shares offset the claim scaler now carries (leg x shares / (supply + 1e6)):
     *      ST: 10e18 of 100e18 senior shares claim 100e18 vault shares -> floor(100e18 x 10e18 / (100e18 + 1e6)) = 9999999999999900000 vault shares.
     *      JT: 3e18 of 30e18 junior shares claim 30e18 vault shares -> floor(30e18 x 3e18 / (30e18 + 1e6)) = 2999999999999900000 vault shares
     *      (post-redemption coverage (90 + 27) x 0.2 / 27 = 0.8667 <= 1, so the coverage gate clears).
     *      LT: 0.5e18 of 6e18 liquidity shares claim 6e18 BPT -> floor(6e18 x 0.5e18 / (6e18 + 1e6)) = 499999999999916666 BPT
     *      (post-redemption ltRawNAV 5.5e18 >= required 90e18 x 0.05 = 4.5e18, so the liquidity gate clears)
     */
    function test_Permit_SignatureSetsAllowanceAndDelegateRedeems() public {
        uint256 deadline = block.timestamp + 1 hours;

        // ===== Senior tranche =====
        vm.prank(ST_PROVIDER);
        seniorTranche.transfer(PERMIT_OWNER, 10e18);
        assertEq(seniorTranche.nonces(PERMIT_OWNER), 0, "a fresh owner must start at nonce zero on the senior tranche");
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(PERMIT_OWNER_KEY, _permitDigest(address(seniorTranche), "Royco Senior Tranche", ST_DELEGATE, 10e18, 0, deadline));
        // Anyone may submit the signed permit, the signature alone authorizes the approval
        seniorTranche.permit(PERMIT_OWNER, ST_DELEGATE, 10e18, deadline, v, r, s);
        assertEq(seniorTranche.allowance(PERMIT_OWNER, ST_DELEGATE), 10e18, "the permit must set the allowance to exactly the signed value");
        assertEq(seniorTranche.nonces(PERMIT_OWNER), 1, "the consumed permit must advance the owner's nonce to 1");

        vm.prank(ST_DELEGATE);
        seniorTranche.redeem(10e18, ST_DELEGATE, PERMIT_OWNER);
        assertEq(
            stJtVault.balanceOf(ST_DELEGATE),
            9_999_999_999_999_900_000,
            "the delegate must receive exactly floor(100e18 x 10e18 / (100e18 + 1e6)) = 9999999999999900000 vault shares"
        );
        assertEq(seniorTranche.balanceOf(PERMIT_OWNER), 0, "the owner's senior shares must be fully redeemed through the permit allowance");
        assertEq(seniorTranche.allowance(PERMIT_OWNER, ST_DELEGATE), 0, "the delegated redemption must consume the permit allowance in full");

        // ===== Junior tranche =====
        vm.prank(JT_PROVIDER);
        juniorTranche.transfer(PERMIT_OWNER, 3e18);
        (v, r, s) = vm.sign(PERMIT_OWNER_KEY, _permitDigest(address(juniorTranche), "Royco Junior Tranche", JT_DELEGATE, 3e18, 0, deadline));
        juniorTranche.permit(PERMIT_OWNER, JT_DELEGATE, 3e18, deadline, v, r, s);
        assertEq(juniorTranche.allowance(PERMIT_OWNER, JT_DELEGATE), 3e18, "the permit must set the junior allowance to exactly the signed value");
        // Each tranche keeps its own nonce ledger, the senior permit above must not have advanced the junior nonce
        assertEq(juniorTranche.nonces(PERMIT_OWNER), 1, "the consumed junior permit must advance that tranche's own nonce to 1");

        vm.prank(JT_DELEGATE);
        juniorTranche.redeem(3e18, JT_DELEGATE, PERMIT_OWNER);
        assertEq(
            stJtVault.balanceOf(JT_DELEGATE),
            2_999_999_999_999_900_000,
            "the delegate must receive exactly floor(30e18 x 3e18 / (30e18 + 1e6)) = 2999999999999900000 vault shares"
        );
        assertEq(juniorTranche.balanceOf(PERMIT_OWNER), 0, "the owner's junior shares must be fully redeemed through the permit allowance");
        assertEq(juniorTranche.allowance(PERMIT_OWNER, JT_DELEGATE), 0, "the delegated junior redemption must consume the permit allowance in full");

        // ===== Liquidity tranche =====
        vm.prank(LT_PROVIDER);
        liquidityTranche.transfer(PERMIT_OWNER, 0.5e18);
        (v, r, s) = vm.sign(PERMIT_OWNER_KEY, _permitDigest(address(liquidityTranche), "Royco Liquidity Tranche", LT_DELEGATE, 0.5e18, 0, deadline));
        liquidityTranche.permit(PERMIT_OWNER, LT_DELEGATE, 0.5e18, deadline, v, r, s);
        assertEq(liquidityTranche.allowance(PERMIT_OWNER, LT_DELEGATE), 0.5e18, "the permit must set the liquidity allowance to exactly the signed value");
        assertEq(liquidityTranche.nonces(PERMIT_OWNER), 1, "the consumed liquidity permit must advance that tranche's own nonce to 1");

        vm.prank(LT_DELEGATE);
        liquidityTranche.redeem(0.5e18, LT_DELEGATE, PERMIT_OWNER);
        assertEq(
            bpt.balanceOf(LT_DELEGATE),
            499_999_999_999_916_666,
            "the delegate must receive exactly floor(6e18 x 0.5e18 / (6e18 + 1e6)) = 499999999999916666 BPT in kind"
        );
        assertEq(liquidityTranche.balanceOf(PERMIT_OWNER), 0, "the owner's liquidity shares must be fully redeemed through the permit allowance");
        assertEq(liquidityTranche.allowance(PERMIT_OWNER, LT_DELEGATE), 0, "the delegated liquidity redemption must consume the permit allowance in full");
    }

    /**
     * @notice A permit past its deadline, a replayed already-consumed signature, and a signature from the wrong key
     *         are all rejected, and none of the failures moves the allowance or the nonce
     * @dev These are the EIP-2612 safety rules that make a signed approval as safe as a sent one: the deadline
     *      bounds how long a leaked signature stays live, the nonce makes every signature single-use, and the
     *      recovered-signer check binds the approval to the owner's key. A gap in any of them would let a
     *      stale or stolen signature drain shares the owner never released
     */
    function test_RevertIf_PermitExpiredReplayedOrWrongSigner() public {
        vm.prank(ST_PROVIDER);
        seniorTranche.transfer(PERMIT_OWNER, 10e18);

        // --- Expired: the deadline check fires before any signature work, one second past is already dead ---
        uint256 expiredDeadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(PERMIT_OWNER_KEY, _permitDigest(address(seniorTranche), "Royco Senior Tranche", ST_DELEGATE, 10e18, 0, expiredDeadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, expiredDeadline));
        seniorTranche.permit(PERMIT_OWNER, ST_DELEGATE, 10e18, expiredDeadline, v, r, s);
        assertEq(seniorTranche.allowance(PERMIT_OWNER, ST_DELEGATE), 0, "an expired permit must not set any allowance");
        assertEq(seniorTranche.nonces(PERMIT_OWNER), 0, "an expired permit must not consume the owner's nonce");

        // --- Replay: consume a valid permit, then resubmit the identical signature ---
        uint256 deadline = block.timestamp + 1 hours;
        (v, r, s) = vm.sign(PERMIT_OWNER_KEY, _permitDigest(address(seniorTranche), "Royco Senior Tranche", ST_DELEGATE, 5e18, 0, deadline));
        seniorTranche.permit(PERMIT_OWNER, ST_DELEGATE, 5e18, deadline, v, r, s);
        assertEq(seniorTranche.allowance(PERMIT_OWNER, ST_DELEGATE), 5e18, "the first submission must set the signed allowance");
        assertEq(seniorTranche.nonces(PERMIT_OWNER), 1, "the first submission must consume nonce 0");
        // The nonce moved to 1, so the verifier now hashes a digest the old signature never signed and recovers
        // an address that is not the owner, single-use is enforced by the nonce, not by remembering signatures
        vm.expectPartialRevert(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector);
        seniorTranche.permit(PERMIT_OWNER, ST_DELEGATE, 5e18, deadline, v, r, s);
        assertEq(seniorTranche.allowance(PERMIT_OWNER, ST_DELEGATE), 5e18, "the replay must not change the allowance");
        assertEq(seniorTranche.nonces(PERMIT_OWNER), 1, "the replay must not consume another nonce");

        // --- Wrong key: a stranger signs the owner's exact permit payload at the current nonce ---
        (address stranger, uint256 strangerKey) = makeAddrAndKey("PERMIT_STRANGER");
        (v, r, s) = vm.sign(strangerKey, _permitDigest(address(seniorTranche), "Royco Senior Tranche", ST_DELEGATE, 10e18, 1, deadline));
        // The signature is well-formed, so recovery yields exactly the stranger, who is not the claimed owner
        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, stranger, PERMIT_OWNER));
        seniorTranche.permit(PERMIT_OWNER, ST_DELEGATE, 10e18, deadline, v, r, s);
        assertEq(seniorTranche.allowance(PERMIT_OWNER, ST_DELEGATE), 5e18, "a wrong-key permit must not change the allowance");
        assertEq(seniorTranche.nonces(PERMIT_OWNER), 1, "a wrong-key permit must not consume the owner's nonce");
    }

    /**
     * @notice While the kernel is paused a permit still sets the allowance, but the delegate's redemption is
     *         blocked until unpause
     * @dev A pause is an emergency stop on asset movement, not on bookkeeping: permit only writes an allowance
     *      (no balance moves, no kernel call), so freezing it would serve no protective purpose and would break
     *      gasless flows queued during an incident. The redeem, which routes into the kernel's whenNotPaused
     *      entrypoint, must stay gated
     */
    function test_Permit_SetsAllowanceWhileKernelPaused() public {
        vm.prank(ST_PROVIDER);
        seniorTranche.transfer(PERMIT_OWNER, 2e18);

        vm.prank(PAUSER);
        kernel.pause();

        // The signature-based approval lands even under pause
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(PERMIT_OWNER_KEY, _permitDigest(address(seniorTranche), "Royco Senior Tranche", ST_DELEGATE, 2e18, 0, deadline));
        seniorTranche.permit(PERMIT_OWNER, ST_DELEGATE, 2e18, deadline, v, r, s);
        assertEq(seniorTranche.allowance(PERMIT_OWNER, ST_DELEGATE), 2e18, "a paused market must still accept the pure-approval permit");
        assertEq(seniorTranche.nonces(PERMIT_OWNER), 1, "the permit must consume the nonce even while paused");

        // The asset-moving half stays frozen: the delegate cannot redeem through the fresh allowance
        vm.prank(ST_DELEGATE);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.redeem(2e18, ST_DELEGATE, PERMIT_OWNER);
        assertEq(seniorTranche.balanceOf(PERMIT_OWNER), 2e18, "no share may move while the market is paused");
        assertEq(seniorTranche.allowance(PERMIT_OWNER, ST_DELEGATE), 2e18, "the failed redemption must not consume the permit allowance");
    }
}
