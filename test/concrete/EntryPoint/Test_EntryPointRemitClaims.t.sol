// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits } from "../../../src/libraries/Units.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { EntryPointRemitClaimsHarness, MockKernelAssets } from "../../mocks/EntryPointRemitClaimsHarness.sol";

/**
 * @title Test_EntryPointRemitClaims
 * @notice Unit-pins the claim-remittance transfer matrix of _remitClaims, including the DIFFERENT-asset ST/JT
 *         branch that the shipped identical-ST/JT-asset kernel family can never produce through a real market:
 *         batch vs per-asset transfers, LT and senior-share legs, and zero-leg skips
 */
contract Test_EntryPointRemitClaims is Test {
    EntryPointRemitClaimsHarness internal harness;
    MockERC20C internal stAsset;
    MockERC20C internal jtAsset;
    MockERC20C internal ltAsset;
    MockERC20C internal seniorShare;

    address internal EXECUTOR = makeAddr("EXECUTOR");
    address internal RECEIVER = makeAddr("RECEIVER");

    function setUp() public {
        harness = new EntryPointRemitClaimsHarness(makeAddr("FACTORY"));
        stAsset = new MockERC20C("ST Asset", "STA", 18);
        jtAsset = new MockERC20C("JT Asset", "JTA", 18);
        ltAsset = new MockERC20C("LT Asset", "LTA", 18);
        seniorShare = new MockERC20C("Senior Share", "RST", 18);
    }

    /// @dev Builds a claims struct over the four transferable legs (nav is untouched by remittance)
    function _claims(uint256 _st, uint256 _jt, uint256 _lt, uint256 _stShares) internal pure returns (AssetClaims memory claims) {
        claims.stAssets = toTrancheUnits(_st);
        claims.jtAssets = toTrancheUnits(_jt);
        claims.ltAssets = toTrancheUnits(_lt);
        claims.stShares = _stShares;
        claims.nav = toNAVUnits(uint256(0));
    }

    function _fundHarness(uint256 _st, uint256 _jt, uint256 _lt, uint256 _stShares) internal {
        if (_st != 0) stAsset.mint(address(harness), _st);
        if (_jt != 0) jtAsset.mint(address(harness), _jt);
        if (_lt != 0) ltAsset.mint(address(harness), _lt);
        if (_stShares != 0) seniorShare.mint(address(harness), _stShares);
    }

    function test_remitClaims_differentAssets_transfersEachLegSeparately() public {
        MockKernelAssets kernel = new MockKernelAssets(address(stAsset), address(jtAsset), address(ltAsset), address(seniorShare));
        _fundHarness(110, 220, 330, 440);

        // user gets (100, 200, 300, 400); executor bonus gets (10, 20, 30, 40)
        vm.prank(EXECUTOR);
        harness.remitClaims(address(kernel), _claims(100, 200, 300, 400), _claims(10, 20, 30, 40), RECEIVER);

        assertEq(stAsset.balanceOf(RECEIVER), 100, "receiver ST asset leg");
        assertEq(jtAsset.balanceOf(RECEIVER), 200, "receiver JT asset leg");
        assertEq(ltAsset.balanceOf(RECEIVER), 300, "receiver LT asset leg");
        assertEq(seniorShare.balanceOf(RECEIVER), 400, "receiver senior share leg");
        assertEq(stAsset.balanceOf(EXECUTOR), 10, "executor ST asset leg");
        assertEq(jtAsset.balanceOf(EXECUTOR), 20, "executor JT asset leg");
        assertEq(ltAsset.balanceOf(EXECUTOR), 30, "executor LT asset leg");
        assertEq(seniorShare.balanceOf(EXECUTOR), 40, "executor senior share leg");
    }

    function test_remitClaims_sameAsset_batchesStAndJtLegs() public {
        MockKernelAssets kernel = new MockKernelAssets(address(stAsset), address(stAsset), address(ltAsset), address(seniorShare));
        _fundHarness(330, 0, 0, 0);

        vm.prank(EXECUTOR);
        harness.remitClaims(address(kernel), _claims(100, 200, 0, 0), _claims(10, 20, 0, 0), RECEIVER);

        assertEq(stAsset.balanceOf(RECEIVER), 300, "receiver must get one batched ST+JT transfer");
        assertEq(stAsset.balanceOf(EXECUTOR), 30, "executor must get one batched ST+JT transfer");
    }

    function test_remitClaims_zeroLegsAreSkippedWithoutReverting() public {
        // The harness holds NO tokens: any attempted transfer would revert, so success proves every leg was skipped
        MockKernelAssets kernel = new MockKernelAssets(address(stAsset), address(jtAsset), address(ltAsset), address(seniorShare));
        vm.prank(EXECUTOR);
        harness.remitClaims(address(kernel), _claims(0, 0, 0, 0), _claims(0, 0, 0, 0), RECEIVER);
    }

    function test_remitClaims_oneSidedLegs_differentAssets() public {
        // Zero bonus with non-zero user claims (and vice versa) must transfer only the non-zero side per leg
        MockKernelAssets kernel = new MockKernelAssets(address(stAsset), address(jtAsset), address(ltAsset), address(seniorShare));
        _fundHarness(100, 20, 300, 40);

        vm.prank(EXECUTOR);
        harness.remitClaims(address(kernel), _claims(100, 0, 300, 0), _claims(0, 20, 0, 40), RECEIVER);

        assertEq(stAsset.balanceOf(RECEIVER), 100, "receiver-only ST leg");
        assertEq(jtAsset.balanceOf(EXECUTOR), 20, "executor-only JT leg");
        assertEq(ltAsset.balanceOf(RECEIVER), 300, "receiver-only LT leg");
        assertEq(seniorShare.balanceOf(EXECUTOR), 40, "executor-only senior share leg");
        assertEq(stAsset.balanceOf(EXECUTOR), 0, "no zero-leg transfer to the executor");
        assertEq(jtAsset.balanceOf(RECEIVER), 0, "no zero-leg transfer to the receiver");
    }
}
