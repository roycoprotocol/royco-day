// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel as DayKernel
} from "../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FixtureCell, MarketParamsConfig } from "../../base/fixtures/FixtureTypes.sol";
import { defaultParams } from "../../base/fixtures/MarketParams.sol";
import { cellA } from "../../base/fixtures/TokenConfigs.sol";
import { TrancheFixture } from "../../base/fixtures/TrancheFixture.sol";
import { MockBPT } from "../../mocks/MockBPT.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";

/// @dev Minimal vault shim registering a pool with three tokens — the only way to reach the quoter constructor's
///      POOL_MUST_HAVE_TWO_TOKENS guard, since MockBalancerVault's registry is structurally two-token.
contract ThreeTokenVaultShim {
    IERC20[] internal _tokens;

    constructor(IERC20[] memory _threeTokens) {
        for (uint256 i; i < _threeTokens.length; ++i) {
            _tokens.push(_threeTokens[i]);
        }
    }

    function isPoolRegistered(address) external pure returns (bool) {
        return true;
    }

    function getPoolTokens(address) external view returns (IERC20[] memory) {
        return _tokens;
    }
}

/**
 * @title BptOracleQuoterTest
 * @notice Balancer battery B1–B4: the LT quoter's oracle guard, constructor guards, BPT<->NAV conversion exactness,
 *         and the senior-share rate provider (cache parity, exactness, floor, transaction-invariance).
 * @dev Mock-based (cell A, default params unless a test states otherwise). setUp only deploys; each test seeds the
 *      exact state it derives its expected values from, so every assertion is exact or a documented floor identity.
 */
contract BptOracleQuoterTest is TrancheFixture {
    function setUp() public virtual {
        _deployMarket(cellA(), defaultParams());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // B1 — setBPTOracle pool-attestation guard (BalancerV3_LT_BPTOracle_Quoter.sol:350)
    // ═══════════════════════════════════════════════════════════════════════════

    /// An oracle pricing a DIFFERENT pool must be rejected: the guard reads LPOracleBase(oracle).pool() and requires
    /// it to equal this market's LT_ASSET.
    function test_setBPTOracle_reverts_whenOraclePricesForeignPool() external {
        MockBPTOracle foreignOracle = new MockBPTOracle(balancerVault, makeAddr("FOREIGN_POOL"));

        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(BalancerV3_LT_BPTOracle_Quoter.BPT_ORACLE_POOL_MISMATCH.selector);
        kernel.setBPTOracle(address(foreignOracle), false);
    }

    /// A right-pool oracle is accepted, the event fires with the new address, storage is updated, and the trailing
    /// sync re-commits the LT raw NAV against the INCOMING oracle's mark.
    function test_setBPTOracle_succeeds_rightPoolOracle_recommitsLtRawNAVAgainstIncomingOracle() external {
        _seedMarket(100e18, 50e18); // JT then ST (auto-seeds minimal quote-only LT depth for the liquidity gate)

        // The replacement oracle prices THIS pool, pinned to a hand-chosen TVL distinct from the outgoing mark.
        MockBPTOracle replacement = new MockBPTOracle(balancerVault, address(bpt));
        replacement.setTVL(3e18);
        replacement.setMode(MockBPTOracle.Mode.MANUAL);

        // Expected committed LT raw NAV under the incoming oracle: floor(TVL * ownedBPT / bptSupply).
        uint256 ownedBpt = toUint256(kernel.getState().ltOwnedYieldBearingAssets);
        uint256 bptSupply = balancerVault.totalSupply(address(bpt));
        uint256 expectedLtRawNAV = Math.mulDiv(3e18, ownedBpt, bptSupply, Math.Rounding.Floor);

        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectEmit(true, false, false, true, address(kernel));
        emit BalancerV3_LT_BPTOracle_Quoter.BPTOracleUpdated(address(replacement));
        kernel.setBPTOracle(address(replacement), true);

        assertEq(kernel.getBalancerV3QuoterState().bptOracle, address(replacement), "oracle storage updated");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), expectedLtRawNAV, "committed LT raw NAV re-marked against incoming oracle");
    }

    /// The zero address has no pool() to attest: the guard's staticcall decodes empty returndata and reverts with
    /// no selector. (Justified bare expectRevert: an empty-returndata abi.decode failure carries no error data.)
    function test_setBPTOracle_reverts_zeroAddressOracle() external {
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert();
        kernel.setBPTOracle(address(0), false);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // B2 — quoter constructor guards (BalancerV3_LT_BPTOracle_Quoter.sol:94-112)
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // NOTE on INVALID_BALANCER_V3_VAULT: unreachable through this kernel family by construction — the concrete
    // kernel derives the constructor's vault FROM the pool (`BalancerPoolToken(ltAsset).getVault()`), so the
    // equality it guards is tautological here. The guard protects future subclasses that pass an explicit vault.

    /// A BPT never registered with its vault fails construction with POOL_NOT_REGISTERED.
    function test_kernelConstructor_reverts_poolNotRegistered() external {
        MockBPT unregisteredBpt = new MockBPT(IVault(address(balancerVault)), "Unregistered BPT", "uBPT");

        vm.expectRevert(BalancerV3_LT_BPTOracle_Quoter.POOL_NOT_REGISTERED.selector);
        new DayKernel(_kernelConstructionParamsWithLtAsset(address(unregisteredBpt)));
    }

    /// A registered pool whose two tokens do not include the senior tranche share fails construction.
    function test_kernelConstructor_reverts_poolWithoutSeniorTrancheLeg() external {
        MockBPT strangerPool = new MockBPT(IVault(address(balancerVault)), "Stranger BPT", "sBPT");
        balancerVault.registerPool(address(strangerPool), [IERC20(address(quoteToken)), IERC20(makeAddr("NOT_THE_SENIOR_TRANCHE"))]);

        vm.expectRevert(BalancerV3_LT_BPTOracle_Quoter.INVALID_POOL_TOKEN_CONFIGURATION.selector);
        new DayKernel(_kernelConstructionParamsWithLtAsset(address(strangerPool)));
    }

    /// A pool reporting three tokens fails construction with POOL_MUST_HAVE_TWO_TOKENS (via the three-token shim,
    /// the only way to produce a non-two-token registration).
    function test_kernelConstructor_reverts_threeTokenPool() external {
        IERC20[] memory three = new IERC20[](3);
        three[0] = IERC20(address(seniorTranche));
        three[1] = IERC20(address(quoteToken));
        three[2] = IERC20(makeAddr("THIRD_TOKEN"));
        ThreeTokenVaultShim shim = new ThreeTokenVaultShim(three);
        MockBPT shimBpt = new MockBPT(IVault(address(shim)), "Shim BPT", "shBPT");

        vm.expectRevert(BalancerV3_LT_BPTOracle_Quoter.POOL_MUST_HAVE_TWO_TOKENS.selector);
        new DayKernel(_kernelConstructionParamsWithLtAsset(address(shimBpt)));
    }

    /// Happy-path constructor resolution: QUOTE_ASSET and the pool indexes come from the registered token order.
    function test_kernelConstructor_resolvesQuoteAssetFromRegistration() external view {
        assertEq(kernel.QUOTE_ASSET(), address(quoteToken), "quote asset resolved from pool registration");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // B3 — ltRawNAV conversion exactness (BalancerV3_LT_BPTOracle_Quoter.sol:132-146)
    // ═══════════════════════════════════════════════════════════════════════════

    /// BPT -> NAV is floor(TVL * bptAmount / bptSupply), pinned against a MANUAL-mode oracle TVL with the expected
    /// value recomputed independently (OZ mulDiv), plus the floor-direction identity value*supply <= TVL*amount.
    function test_ltConvertTrancheUnitsToNAVUnits_exactFloorAgainstPinnedTVL() external {
        bptOracle.setTVL(7e18);
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);

        uint256 bptSupply = balancerVault.totalSupply(address(bpt));
        assertGt(bptSupply, 0, "arrange: genesis minimum supply must exist");

        // A conversion amount chosen to force a non-exact division (7e18 * 3 not divisible by the genesis supply).
        uint256 amount = (bptSupply / 3) + 1;
        uint256 expected = Math.mulDiv(7e18, amount, bptSupply, Math.Rounding.Floor);

        uint256 got = toUint256(kernel.ltConvertTrancheUnitsToNAVUnits(toTrancheUnits(amount)));
        assertEq(got, expected, "floor(TVL * amount / supply)");
        // Floor direction: the conversion never overstates the LT's NAV.
        assertLe(got * bptSupply, 7e18 * amount, "floor bias never overstates NAV");
    }

    /// NAV -> BPT is the inverse floor: floor(supply * value / TVL).
    function test_ltConvertNAVUnitsToTrancheUnits_exactFloorAgainstPinnedTVL() external {
        bptOracle.setTVL(7e18);
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);

        uint256 bptSupply = balancerVault.totalSupply(address(bpt));
        uint256 value = 1e18 + 3; // deliberately non-divisible
        uint256 expected = Math.mulDiv(bptSupply, value, 7e18, Math.Rounding.Floor);

        assertEq(toUint256(kernel.ltConvertNAVUnitsToTrancheUnits(toNAVUnits(value))), expected, "floor(supply * value / TVL)");
    }

    /// A reverting oracle bricks the LT mark: the conversion path surfaces the oracle failure rather than guessing.
    function test_ltConvert_revertsWhenOracleReverts() external {
        bptOracle.setRevertMode(true);
        vm.expectRevert(MockBPTOracle.ORACLE_REVERT_MODE.selector);
        kernel.ltConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // B4 — senior-share rate provider (BalancerV3_LT_BPTOracle_Quoter.sol:160-180)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Before the senior tranche is seeded the rate floors to exactly 1 wei (never zero: the pool rejects zero rates).
    function test_getRate_flooredToOneWeiOnUnseededMarket() external view {
        assertEq(kernel.getRate(), 1, "1-wei floor with zero ST supply");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Construction params identical to the live market's kernel except the LT asset (the pool under test).
    function _kernelConstructionParamsWithLtAsset(address _ltAsset) internal view returns (IRoycoDayKernel.RoycoDayKernelConstructionParams memory) {
        return IRoycoDayKernel.RoycoDayKernelConstructionParams({
            seniorTranche: address(seniorTranche),
            stAsset: address(stJtVault),
            juniorTranche: address(juniorTranche),
            jtAsset: address(stJtVault),
            accountant: address(accountant),
            liquidityTranche: address(liquidityTranche),
            ltAsset: _ltAsset,
            enforceVaultSharesTransferWhitelist: false
        });
    }
}

/**
 * @title GetRateSeededZeroFeeTest
 * @notice B4's seeded rate-provider tests on a zero-fee/zero-premium market, hand-exact by construction.
 * @dev Seeding happens in setUp DELIBERATELY: Foundry clears transient storage between setUp and the test body, so
 *      each test starts with an unset ST_SHARE_RATE cache — mirroring production, where every user interaction is
 *      its own transaction. (Seeding inside a test body leaves the seeding syncs' cache visible to the assertions.)
 */
contract GetRateSeededZeroFeeTest is TrancheFixture {
    function setUp() public virtual {
        MarketParamsConfig memory p = defaultParams();
        p.stProtocolFeeWAD = 0;
        p.jtProtocolFeeWAD = 0;
        p.jtYieldShareProtocolFeeWAD = 0;
        p.ltYieldShareProtocolFeeWAD = 0;
        p.maxJTYieldShareWAD = 0;
        p.maxLTYieldShareWAD = 0;
        p.jtCurve = [uint64(0), uint64(0), uint64(0)];
        p.ltCurve = [uint64(0), uint64(0), uint64(0)];
        _deployMarket(cellA(), p);
        _seedMarket(100e18, 50e18);
    }

    /// Live path exactness + cache parity, hand-derived on the zero-fee/zero-premium market:
    ///   seeded 100e18 ST at rate 1.0 => stEff = 100e18, supply = 100e18 => rate = 1.0
    ///   accrue +10% vault rate       => stEff = 110e18, supply unchanged (no fee/premium carve-out)
    ///   => live rate == floor(110e18 * 1e18 / 100e18) == 1.1e18, and the post-sync cached rate must equal it.
    function test_getRate_livePathExact_andCacheParityAfterSync() external {
        applySTPnL(1000); // +10.00%
        uint256 liveRate = kernel.getRate(); // cache unset at test entry: live preview path
        assertEq(liveRate, 1.1e18, "live rate == hand-derived 1.1e18");

        vm.prank(SYNC_OPERATOR);
        kernel.syncTrancheAccounting(); // writes the ST_SHARE_RATE transient cache
        assertEq(kernel.getRate(), liveRate, "cached rate == live rate (same block, same state)");
    }

    /// Transaction-invariance (the R7 cache guarantee): once a sync has cached the rate, an inline senior-share mint
    /// (supply +100%) cannot move the rate the venue sees within the same transaction.
    function test_getRate_transactionInvariant_underInlineSeniorMint() external {
        vm.prank(SYNC_OPERATOR);
        kernel.syncTrancheAccounting();
        uint256 cachedRate = kernel.getRate();
        assertEq(cachedRate, 1e18, "arrange: cached rate at seed is exactly 1.0");

        // Inline senior mint: doubles the supply mid-transaction (the tranche's onlyKernel gate).
        vm.prank(address(kernel));
        seniorTranche.mint(makeAddr("INLINE_MINT_RECIPIENT"), 100e18);

        assertEq(kernel.getRate(), cachedRate, "rate unchanged by an inline supply move: the cache pins it");
    }
}
