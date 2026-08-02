// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { Initializable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { RoycoDayBalancerV3Kernel as DayKernel } from "../../../src/kernels/RoycoDayBalancerV3Kernel.sol";
import { BalancerV3LiquidityVenue } from "../../../src/kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoLiquidityProviderTranche } from "../../../src/tranches/RoycoLiquidityProviderTranche.sol";
import { RoycoSeniorTranche } from "../../../src/tranches/RoycoSeniorTranche.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { MockBPT } from "../../mocks/MockBPT.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockERC4626C } from "../../mocks/MockERC4626C.sol";
import { MockPriceOracle } from "../../mocks/MockPriceOracle.sol";
import { MockThreeTokenVaultShim } from "../../mocks/MockThreeTokenVaultShim.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { IBalancerV3LiquidityVenue } from "../../../src/interfaces/liquidity-venue/IBalancerV3LiquidityVenue.sol";

/**
 * @title Test_Initialization_Kernel
 * @notice Exercises the kernel family's initialization-time validation: null wiring, the coinvested tranche-vs-kernel
 *         collateral asset agreement, the liquidity pool's registration and token-pairing checks, and the genesis
 *         collateral oracle pricing path
 * @dev Every one of these checks used to run in the kernel's constructor. The implementation is market-independent
 *      now — its only construction input is the Balancer Vault — so the whole market wiring arrives through
 *      `initialize`, and that is where each rejection path lives
 * @dev These checks only ever run at market genesis, but each one guards a wiring mistake that would be
 *      unrecoverable behind the proxy once real deposits land, so every rejection path is pinned here
 */
contract Test_Initialization_Kernel is DayMarketTestBase {
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
    }

    /// @dev A fresh, market-independent kernel implementation, shared by every market on the chain
    function _freshImpl() internal returns (DayKernel) {
        return new DayKernel(IVault(address(balancerVault)));
    }

    /// @dev Builds init params identical to the deployed market's kernel, then tests mutate one field at a time
    function _goodInitParams(
        address _collateralAssetOracle,
        address _protocolFeeRecipient
    )
        internal
        view
        returns (IRoycoDayKernel.RoycoDayKernelInitParams memory standardParams, IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory venueParams)
    {
        standardParams = IRoycoDayKernel.RoycoDayKernelInitParams({
            initialAuthority: address(accessManager),
            seniorTranche: address(seniorTranche),
            juniorTranche: address(juniorTranche),
            liquidityProviderTranche: address(liquidityProviderTranche),
            collateralAsset: address(stJtVault),
            lptAsset: address(bpt),
            quoteAsset: address(quoteToken),
            accountant: address(accountant),
            protocolFeeRecipient: _protocolFeeRecipient,
            stSelfLiquidationBonusWAD: 0.01e18,
            roycoBlacklist: address(0),
            collateralAssetOracle: _collateralAssetOracle,
            stalenessThresholdSeconds: 1 days,
            sequencerUptimeFeed: address(0),
            gracePeriodSeconds: 1 hours
        });
        venueParams = IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams({ bptOracle: address(bptOracle), maxReinvestmentSlippageWAD: 0.001e18 });
    }

    /// @dev Deploys a kernel proxy over a fresh implementation, expecting the given revert
    function _expectInitRevert(
        IRoycoDayKernel.RoycoDayKernelInitParams memory _standardParams,
        IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory _venueParams,
        bytes4 _selector
    )
        internal
    {
        DayKernel impl = _freshImpl();
        bytes memory initData = abi.encodeCall(impl.initialize, (_standardParams, _venueParams));
        vm.expectRevert(_selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @dev A liquidity provider tranche custodying an arbitrary asset, so the venue's pool checks are reachable
    ///      past the kernel's tranche-asset agreement check
    function _lptCustodying(address _asset) internal returns (address) {
        return _deployTrancheProxy(address(lptBeacon), "Foreign LPT", "fLPT", address(kernel), _asset);
    }

    // =============================
    // Wiring rejections
    // =============================

    /// @notice A null senior tranche in the market wiring is rejected before anything else can be mis-set
    function test_RevertIf_KernelInitializedWithNullSeniorTranche() public {
        (IRoycoDayKernel.RoycoDayKernelInitParams memory sp, IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory vp) =
            _goodInitParams(address(collateralAssetOracle), PROTOCOL_FEE_RECIPIENT);
        sp.seniorTranche = address(0);
        _expectInitRevert(sp, vp, IRoycoAuth.NULL_ADDRESS.selector);
    }

    /// @notice A liquidity provider tranche asset that is not a registered Balancer pool is rejected
    function test_RevertIf_LPTAssetPoolNotRegisteredWithVault() public {
        MockBPT unregisteredBpt = new MockBPT(IVault(address(balancerVault)), "Unregistered BPT", "uBPT");
        (IRoycoDayKernel.RoycoDayKernelInitParams memory sp, IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory vp) =
            _goodInitParams(address(collateralAssetOracle), PROTOCOL_FEE_RECIPIENT);
        sp.lptAsset = address(unregisteredBpt);
        sp.liquidityProviderTranche = _lptCustodying(address(unregisteredBpt));
        _expectInitRevert(sp, vp, BalancerV3LiquidityVenue.POOL_NOT_REGISTERED.selector);
    }

    /// @notice A registered pool that does not pair the senior tranche share is rejected, the LPT must market-make senior exits
    function test_RevertIf_LPTAssetPoolDoesNotPairSeniorTranche() public {
        MockBPT foreignBpt = new MockBPT(IVault(address(balancerVault)), "Foreign BPT", "fBPT");
        MockERC20C tokenA = new MockERC20C("Token A", "TKA", 18);
        MockERC20C tokenB = new MockERC20C("Token B", "TKB", 6);
        balancerVault.registerPool(address(foreignBpt), [IERC20(address(tokenA)), IERC20(address(tokenB))]);

        (IRoycoDayKernel.RoycoDayKernelInitParams memory sp, IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory vp) =
            _goodInitParams(address(collateralAssetOracle), PROTOCOL_FEE_RECIPIENT);
        sp.lptAsset = address(foreignBpt);
        sp.liquidityProviderTranche = _lptCustodying(address(foreignBpt));
        _expectInitRevert(sp, vp, BalancerV3LiquidityVenue.INVALID_POOL_TOKEN_CONFIGURATION.selector);
    }

    /// @notice A pool reporting three tokens is rejected, the LPT pool must be exactly the senior share against one quote
    function test_RevertIf_LPTAssetPoolReportsThreeTokens() public {
        IERC20[] memory three = new IERC20[](3);
        three[0] = IERC20(address(seniorTranche));
        three[1] = IERC20(address(quoteToken));
        three[2] = IERC20(makeAddr("THIRD_TOKEN"));
        MockThreeTokenVaultShim shim = new MockThreeTokenVaultShim(three);
        MockBPT shimBpt = new MockBPT(IVault(address(shim)), "Shim BPT", "shBPT");

        (IRoycoDayKernel.RoycoDayKernelInitParams memory sp, IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory vp) =
            _goodInitParams(address(collateralAssetOracle), PROTOCOL_FEE_RECIPIENT);
        sp.lptAsset = address(shimBpt);
        sp.liquidityProviderTranche = _lptCustodying(address(shimBpt));

        // The impl must be constructed against the shim vault: the venue's vault-agreement guard
        // (INVALID_BALANCER_V3_VAULT) runs before the token-count guard, and this test pins the latter
        DayKernel impl = new DayKernel(IVault(address(shim)));
        bytes memory initData = abi.encodeCall(impl.initialize, (sp, vp));
        vm.expectRevert(BalancerV3LiquidityVenue.POOL_MUST_HAVE_TWO_TOKENS.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @notice A tranche wired with a null asset or a null kernel is rejected at its own initialization
    function test_RevertIf_TrancheInitializedWithNullAssetOrKernel() public {
        RoycoSeniorTranche impl = new RoycoSeniorTranche();
        IRoycoVaultTranche.RoycoTrancheInitParams memory p = IRoycoVaultTranche.RoycoTrancheInitParams({
            name: "T",
            symbol: "T",
            initialAuthority: address(accessManager),
            kernel: address(kernel),
            asset: address(0)
        });
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(RoycoSeniorTranche.initialize, (p)));

        p.asset = address(stJtVault);
        p.kernel = address(0);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(RoycoSeniorTranche.initialize, (p)));
    }

    /// @notice A kernel whose recorded collateral asset disagrees with what the tranches actually custody is rejected
    function test_RevertIf_KernelInitializedWithMismatchedTrancheAsset() public {
        MockERC4626C foreignVault = new MockERC4626C(address(stJtUnderlying), "Foreign Vault Share", "fSHARE", 18);
        foreignVault.setRate(1e18);
        (IRoycoDayKernel.RoycoDayKernelInitParams memory sp, IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory vp) =
            _goodInitParams(address(collateralAssetOracle), PROTOCOL_FEE_RECIPIENT);
        sp.collateralAsset = address(foreignVault);
        _expectInitRevert(sp, vp, IRoycoDayKernel.TRANCHE_AND_KERNEL_ASSETS_MISMATCH.selector);
    }

    /**
     * @notice A junior tranche custodying anything other than the kernel's collateral asset is rejected: both tranches
     *         must deposit the one coinvested collateral asset so the junior tranche's capital carries the senior exposure
     */
    function test_RevertIf_KernelInitializedWithForeignJuniorTrancheAsset() public {
        MockERC4626C foreignVault = new MockERC4626C(address(stJtUnderlying), "Foreign Vault Share", "fSHARE", 18);
        foreignVault.setRate(1e18);
        (IRoycoDayKernel.RoycoDayKernelInitParams memory sp, IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory vp) =
            _goodInitParams(address(collateralAssetOracle), PROTOCOL_FEE_RECIPIENT);
        sp.juniorTranche = _deployTrancheProxy(address(lptBeacon), "Foreign JT", "fJT", address(kernel), address(foreignVault));
        _expectInitRevert(sp, vp, IRoycoDayKernel.TRANCHE_AND_KERNEL_ASSETS_MISMATCH.selector);
    }

    /// @notice A null protocol fee recipient is rejected, sync-time fee mints need a live destination
    function test_RevertIf_KernelInitializedWithNullFeeRecipient() public {
        (IRoycoDayKernel.RoycoDayKernelInitParams memory sp, IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory vp) =
            _goodInitParams(address(collateralAssetOracle), address(0));
        _expectInitRevert(sp, vp, IRoycoAuth.NULL_ADDRESS.selector);
    }

    /**
     * @notice An attacker cannot re-initialize the live kernel proxy to seize its authority or rewire its pricing
     * @dev Re-initialization is the classic proxy takeover: a second initialize call with attacker-controlled
     *      params would replace the access authority and the fee recipient in one transaction
     */
    function test_RevertIf_KernelReinitializedAfterGenesis() public {
        (IRoycoDayKernel.RoycoDayKernelInitParams memory sp, IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory vp) =
            _goodInitParams(address(collateralAssetOracle), makeAddr("ATTACKER"));
        sp.initialAuthority = makeAddr("ATTACKER_AUTHORITY");
        vm.prank(makeAddr("ATTACKER"));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        kernel.initialize(sp, vp);
    }

    // =============================
    // Oracle validation
    // =============================

    /// @notice A null collateral asset oracle is rejected, the kernel has no fallback price source
    function test_RevertIf_KernelInitializedWithNullOracle() public {
        (IRoycoDayKernel.RoycoDayKernelInitParams memory sp, IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory vp) =
            _goodInitParams(address(0), PROTOCOL_FEE_RECIPIENT);
        _expectInitRevert(sp, vp, IRoycoAuth.NULL_ADDRESS.selector);
    }

    /// @notice A zero staleness threshold is rejected, it would flag every report stale and brick pricing
    function test_RevertIf_KernelInitializedWithZeroStalenessThreshold() public {
        (IRoycoDayKernel.RoycoDayKernelInitParams memory sp, IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory vp) =
            _goodInitParams(address(collateralAssetOracle), PROTOCOL_FEE_RECIPIENT);
        sp.stalenessThresholdSeconds = 0;
        _expectInitRevert(sp, vp, IRoycoDayKernel.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
    }

    /// @notice An oracle pricing a different collateral asset is rejected, the pairing can never mismatch
    function test_RevertIf_KernelInitializedWithMismatchedOracle() public {
        MockPriceOracle foreignOracle = new MockPriceOracle(makeAddr("FOREIGN_ASSET"), 1e18);
        (IRoycoDayKernel.RoycoDayKernelInitParams memory sp, IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory vp) =
            _goodInitParams(address(foreignOracle), PROTOCOL_FEE_RECIPIENT);
        _expectInitRevert(sp, vp, IRoycoDayKernel.COLLATERAL_ASSET_ORACLE_MISMATCH.selector);
    }

    /// @notice A sequencer uptime feed with a zero grace period is rejected, a restore needs a settling window
    function test_RevertIf_KernelInitializedWithSequencerFeedAndZeroGracePeriod() public {
        (IRoycoDayKernel.RoycoDayKernelInitParams memory sp, IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory vp) =
            _goodInitParams(address(collateralAssetOracle), PROTOCOL_FEE_RECIPIENT);
        sp.sequencerUptimeFeed = makeAddr("SEQUENCER_UPTIME_FEED");
        sp.gracePeriodSeconds = 0;
        _expectInitRevert(sp, vp, IRoycoDayKernel.INVALID_GRACE_PERIOD_SECONDS.selector);
    }

    /**
     * @notice A kernel initialized against an oracle at a non-unit price prices through that oracle from genesis
     * @dev The deployed fixture kernel wires the shared oracle at 1.0, so this deploys a sibling kernel proxy over
     *      the same market wiring against a fresh oracle at 3.0: one whole share must quote 1e18 x 3e18 / 1e18 = 3e18 NAV
     */
    function test_KernelInitializedWithOracle_PricesThroughItFromGenesis() public {
        MockPriceOracle seededOracle = new MockPriceOracle(address(stJtVault), 3e18);
        DayKernel freshImpl = _freshImpl();
        (IRoycoDayKernel.RoycoDayKernelInitParams memory sp, IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory vp) =
            _goodInitParams(address(seededOracle), PROTOCOL_FEE_RECIPIENT);
        DayKernel seededKernel = DayKernel(address(new ERC1967Proxy(address(freshImpl), abi.encodeCall(freshImpl.initialize, (sp, vp)))));

        assertEq(seededKernel.getCollateralAssetOracle(), address(seededOracle), "the initialization oracle must land as the kernel's collateral oracle");
        assertEq(toUint256(seededKernel.convertCollateralAssetsToValue(toTrancheUnits(1e18))), 3e18, "one whole share must quote at the oracle's 3.0 price");
    }
}

/**
 * @title Test_PreGenesisConversions_Kernel
 * @notice The liquidity venue's zero-supply boundary: before the pool's genesis mint the BPT supply is zero, and both
 *         conversion directions must resolve to zero instead of dividing by the empty supply
 * @dev Overrides the fixture's pool-genesis hook to skip the minimum-supply backing, leaving a validly registered
 *      pool whose BPT supply is exactly zero
 */
contract Test_PreGenesisConversions_Kernel is DayMarketTestBase {
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
    }

    /// @dev Skips the genesis seed so the registered pool's BPT supply stays at exactly zero
    function _initializePoolMinimumSupply() internal override { }

    /// @notice With zero BPT outstanding the BPT to NAV direction floors to zero, the NAV to BPT direction reverts on the
    ///         zero-price division. Production never reaches the reverting direction on an empty pool: AssetLedgerLogic
    ///         guards convertValueToLPTAssets behind lptRawNAV != 0 (which requires held BPT, hence a nonzero supply) and
    ///         the reinvestment probe tolerates it via _tryExecute, so the panic is unreachable and a direct external call
    ///         fails loud rather than fabricating a BPT amount from a null price
    function test_LPTConversions_ZeroBptSupply_BptToNavZero_NavToBptReverts() public {
        assertEq(toUint256(kernel.convertLPTAssetsToValue(toTrancheUnits(5e18))), 0, "BPT -> NAV on an empty pool must be zero");
        // Reverts with a division-by-zero panic (0x12) on the null price
        vm.expectRevert();
        kernel.convertValueToLPTAssets(toNAVUnits(uint256(5e18)));
    }
}
