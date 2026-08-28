/*
 * =====================================================================================================
 *  Royco Day — external-actor summaries for the RoycoDayAccountant verification job
 * =====================================================================================================
 *
 *  This file contains ONLY the summarization of the external (non-provided) actors that
 *  RoycoDayAccountant reaches transitively, plus the ghost state and CVL functions those summaries need.
 *  It declares no rules and no invariants.
 *
 *  Scope (exactly the four interfaces identified as out-of-protocol actors):
 *    * Chainlink Price Feeds        -> AggregatorV3Interface.latestRoundData()
 *    * Chainalysis Sanctions List   -> ISanctionsList.isSanctioned(address)
 *    * Idle Finance Protocol        -> IIdleCDO.virtualPrice(address)
 *    * Makina Protocol             -> IMachine.lastGlobalAccountingTime(), IMachine.convertToAssets(uint256)
 *
 *  Shape of every entry below (and why):
 *    - WILDCARD receiver (`_.f(...)`): the instances are chosen per-market by governance and are not part
 *      of the provided contract set, so there is no contract to name. Each wildcard entry therefore
 *      carries an `expect` clause derived from the interface declarations above.
 *    - Default application policy (`UNRESOLVED`) is intentionally kept. No provided contract
 *      (accountant/kernel/tranche/YDM/oracle-adapter harnesses, RoycoBlacklist, DummyERC20Impl)
 *      implements any of these signatures, so every one of these call sites is unresolved and the
 *      summaries do reach them. Nothing is silently skipped, and no resolved (real-code) call site is
 *      overridden.
 *    - EXPRESSION summaries backed by GHOST STATE rather than `NONDET`. All five callees are `view` in the
 *      real world, so the "state untouched" half of the model is sound. The ghost mappings act as the
 *      storage of these unknown contracts, keyed by `calledContract`, so:
 *        (a) one model covers unboundedly many feed / list / CDO / machine instances, and
 *        (b) reads are mutually consistent within a rule -- two reads of the same feed inside one
 *            operation frame cannot disagree, which `NONDET` would wrongly allow.
 *      The ghosts are regular (not `persistent`): they mirror storage-like external state, so they are
 *      havoced/rolled back exactly when contract storage is.
 *    - VALUES ARE LEFT UNCONSTRAINED. These actors are modelled as honest but opaque: validation of the
 *      answer's sign, of the report's age, and of the machine's accounting freshness lives in the calling
 *      adapter's own code (ChainlinkPriceOracleBase.getPrice, MakinaSharePriceOracle.getPrice,
 *      the clocked bases) and runs for real. Constraining the ghosts here would prune the adapters'
 *      fail-shut branches. This is an over-approximation on the return axis: spurious counterexamples are
 *      possible, nothing is hidden.
 *
 *  What these summaries EXCLUDE (documented verification assumptions):
 *    - Reentrancy / state mutation by these callees: none is modelled (they are `view` in reality).
 *    - Reverting sources: a feed / sanctions list / CDO / machine that reverts (or returns malformed or
 *      short returndata) is not modelled; every summarized call returns a well-formed value. Properties
 *      about how the protocol handles a reverting oracle or a reverting sanctions list are therefore out
 *      of scope for this configuration.
 *    - Non-determinism across calls with identical arguments is excluded by construction (that is the
 *      point of the ghost backing): a source that changes its answer mid-transaction is not modelled.
 */

// ---------------------------------------------------------------------------------------------------
//  Ghost state: the "storage" of the unknown external contracts
// ---------------------------------------------------------------------------------------------------

// Chainlink (compatible) feeds, keyed by feed address. Covers both the NAV-unit hop of every collateral
// oracle adapter and the kernel's optional L2 sequencer-uptime feed (whose status is the `answer` field).
ghost mapping(address => uint80)  feedRoundIdGhost;
ghost mapping(address => int256)  feedAnswerGhost;
ghost mapping(address => uint256) feedStartedAtGhost;
ghost mapping(address => uint256) feedUpdatedAtGhost;
ghost mapping(address => uint80)  feedAnsweredInRoundGhost;

// Chainalysis sanctions designation, per sanctions-list instance and per screened account.
ghost mapping(address => mapping(address => bool)) sanctionedGhost;

// Idle CDO virtual price, per CDO instance and per tranche token (AA / BB).
ghost mapping(address => mapping(address => uint256)) cdoVirtualPriceGhost;

// Makina machine: last global accounting timestamp, per machine instance.
ghost mapping(address => uint256) machineAccountingTimeGhost;

// Makina machine: share -> accounting-asset conversion, per machine instance and per share amount.
// Keying on the share amount gives the functional consistency a deterministic conversion has.
ghost mapping(address => mapping(uint256 => uint256)) convertToAssetsGhost;

// ---------------------------------------------------------------------------------------------------
//  Summaries
// ---------------------------------------------------------------------------------------------------

methods {
    /*
     * Chainlink Price Feeds (AggregatorV3Interface).
     *
     * Assumes: the feed is an honest, opaque, side-effect-free source; every read of a given feed inside a
     * rule reports the same round. Nothing is assumed about the sign of `answer` or the age of `updatedAt`
     * -- the calling adapter's `INVALID_PRICE` / `STALE_FEED_PRICE` gates (and the kernel's sequencer-down
     * plus grace-period gate) are checked against the symbolic values, so both the accepted and the
     * fail-shut branches remain reachable.
     * Safe for the accountant's properties because the accountant only ever consumes a *price already
     * validated and marked by the kernel*; what matters is that the price be an arbitrary positive number,
     * which this permits.
     * Excludes: feeds that revert, feeds that return short/malformed data, and feeds that answer
     * differently to two reads within one transaction.
     * Expected reach: `ORACLE.latestRoundData()` in ChainlinkPriceOracleBase.getPrice() (used by all four
     * adapter harnesses) and the kernel's direct read of the L2 sequencer-uptime feed. `decimals()` is read
     * only in the adapters' constructors, which summarization cannot reach, and is deliberately not
     * entered here.
     */
    function _.latestRoundData() external
        => cvlLatestRoundData(calledContract)
        expect (uint80, int256, uint256, uint256, uint80);

    /*
     * Chainalysis Sanctions List (ISanctionsList).
     *
     * Assumes: an opaque, honest, side-effect-free boolean compliance oracle whose verdict is stable per
     * (list, account) within a rule. The verdict itself is symbolic, so both the screened and the
     * unscreened worlds are explored; RoycoBlacklist ORs it with its local mapping and reverts in its own
     * code, so the compliance chokepoint's behaviour is verified rather than assumed.
     * Excludes: a sanctions list that reverts (real deployments exist that do), and one that flips its
     * verdict for the same account mid-transaction.
     * Expected reach: `ISanctionsList(sanctionsList).isSanctioned(_account)` inside
     * RoycoBlacklist._isSanctioned, reached whenever the kernel screens a party -- notably the ST/JT
     * protocol-fee and liquidity-premium share mints performed during a sync. Skipped entirely by the
     * contract when no list is configured, which the summary does not disturb.
     */
    function _.isSanctioned(address account) external
        => cvlIsSanctioned(calledContract, account)
        expect bool;

    /*
     * Idle Finance Protocol (IIdleCDO).
     *
     * Assumes: an honest, opaque, side-effect-free virtual price, stable per (CDO, tranche) within a rule.
     * The value is symbolic and unbounded; the adapter's own decimal multiplier and synthetic deviation
     * clock run on it for real, so the clock's checkpoint/staleness logic is verified, not assumed.
     * Excludes: a CDO that reverts, and one that reprices between two reads in the same transaction.
     * Expected reach: `IIdleCDO(IDLE_CDO).virtualPrice(COLLATERAL_ASSET)` in
     * IdleCDOTranchePriceOracle._getSourcePrice() (runtime reads only; the AATranche()/BBTranche()/token()
     * validation reads happen in the constructor, out of summarization's reach, and are not entered here).
     */
    function _.virtualPrice(address tranche) external
        => cvlVirtualPrice(calledContract, tranche)
        expect uint256;

    /*
     * Makina Protocol (IMachine) -- native accounting clock.
     *
     * Assumes: the machine honestly reports its own last global accounting time, side-effect free and
     * stable within a rule. The timestamp is symbolic, so MakinaSharePriceOracle's STALE_MAKINA_ACCOUNTING
     * gate and its `min(feedUpdatedAt, makinaAccountingUpdatedAt)` composition are both exercised.
     * Excludes: a machine that reverts on this read.
     * Expected reach: `IMachine(MAKINA_MACHINE).lastGlobalAccountingTime()` in
     * MakinaSharePriceOracle.getPrice().
     */
    function _.lastGlobalAccountingTime() external
        => cvlLastGlobalAccountingTime(calledContract)
        expect uint256;

    /*
     * Makina Protocol (IMachine) -- share to accounting-asset conversion.
     *
     * Assumes: a deterministic, side-effect-free conversion: the same machine and the same share amount
     * always convert to the same asset amount within a rule (that is what the ghost keyed on the share
     * amount buys over NONDET). The rate itself is symbolic and unbounded, so no monotonicity, linearity
     * or scale relationship between different share amounts is assumed either -- only per-argument
     * consistency.
     * Excludes: a machine that reverts, and one whose rate moves between two reads in one transaction.
     * Expected reach: `IMachine(MAKINA_MACHINE).convertToAssets(...)` in
     * MakinaSharePriceOracle._getCollateralToReferenceAssetConversionRateWAD().
     * NOTE (incidental reach): because the wildcard receiver is mandated, this entry also matches the
     * `convertToAssets(uint256)` read that ERC4626SharePriceOracle performs on an unknown ERC-4626 vault.
     * The modelled semantics (deterministic, view, symbolic rate) are the same for that actor, so the model
     * is appropriate there too -- but the extension of reach beyond the Makina machine is deliberate and
     * flagged. The alternative ERC-4626 path, `previewRedeem`, is NOT summarized here (out of scope) and
     * keeps the Prover's default treatment.
     */
    function _.convertToAssets(uint256 shares) external
        => cvlConvertToAssets(calledContract, shares)
        expect uint256;
}

// ---------------------------------------------------------------------------------------------------
//  Summary bodies
// ---------------------------------------------------------------------------------------------------

/// Models one Chainlink (compatible) round report for `feed`. Side-effect free; all five fields are
/// symbolic but consistent per feed. Every field is read straight out of the ghost state, so no numeric
/// cast (and hence no vacuity risk) is involved.
function cvlLatestRoundData(address feed) returns (uint80, int256, uint256, uint256, uint80) {
    return (
        feedRoundIdGhost[feed],
        feedAnswerGhost[feed],
        feedStartedAtGhost[feed],
        feedUpdatedAtGhost[feed],
        feedAnsweredInRoundGhost[feed]
    );
}

/// Models the sanctions designation of `account` under the sanctions list at `sanctionsList`.
function cvlIsSanctioned(address sanctionsList, address account) returns bool {
    return sanctionedGhost[sanctionsList][account];
}

/// Models the Idle CDO at `cdo` reporting the virtual price of its `tranche` token, denominated in the
/// CDO underlying token's decimals (the adapter lifts it to WAD precision itself).
function cvlVirtualPrice(address cdo, address tranche) returns uint256 {
    return cdoVirtualPriceGhost[cdo][tranche];
}

/// Models the Makina machine at `machine` reporting its own last global accounting timestamp.
function cvlLastGlobalAccountingTime(address machine) returns uint256 {
    return machineAccountingTimeGhost[machine];
}

/// Models the machine at `machine` converting `shares` into accounting assets: an arbitrary but
/// per-argument deterministic function.
function cvlConvertToAssets(address machine, uint256 shares) returns uint256 {
    return convertToAssetsGhost[machine][shares];
}
