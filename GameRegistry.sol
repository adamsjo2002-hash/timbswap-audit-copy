// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITimbYieldVaultRegistry {
    function register(uint256 ticketId, address token, uint256 amount) external;
    function remove(uint256 ticketId) external;
}

interface ITimbPrizePot {
    /// @notice Permissionless ETH recycle into the live prize pot.
    function addToPot() external payable;
}

/**
 * @title GameRegistry (v2 — ticket model)
 * @notice Prize game ticket storage, escrow, lifecycle, and yield-weight hooks.
 *
 * Ticket model:
 *   - Every entry mints a Ticket with a globally unique id.
 *   - One eligible live ticket per wallet, enforced via activeTicketOf.
 *   - Replacement mints a NEW ticket; the senior ticket becomes Conceded and
 *     stays visible, cross-linked (supersedes / supersededBy). The principal
 *     moves onto the replacement; extra-round TIMBS on the conceded ticket is
 *     already forfeited to the protocol sink (Treasury) and must be re-paid
 *     for the replacement to carry extra rounds again.
 *   - Tickets are indexed into EVERY round they are eligible for
 *     (playRound..lastEligibleRound), fixing the v1 bug where extra-round
 *     entries could never win or activate beyond their first round.
 *
 * Ticket statuses:
 *   Pending    — waiting for its play round to begin.
 *   Active     — counted into the round; escrow weight registered in the
 *                yield vault (earning for the prize pool); eligible to win.
 *                After lastEligibleRound passes it is refundable (derived,
 *                not a stored status) within the refund window.
 *   Conceded   — replaced; ineligible to win; principal moved to replacement;
 *                stays visible tethered beneath the replacement.
 *   Ineligible — refund window lapsed unclaimed (escrow absorbed to protocol
 *                sink) or admin-flagged ticket/game inconsistency.
 *   Cancelled  — voluntary pre-round withdrawal; principal refunded; no tally.
 *                Reported as Closed (derived) once its play round begins.
 *   Closed     — principal withdrawn; terminal; hidden from active lists.
 *
 * Yield hooks (TimbYieldVault):
 *   - Weight registered when a ticket becomes Active, removed the moment it
 *     stops being eligible (conceded / expired / ineligible / refunded).
 *   - Principal NEVER moves to the vault — weight is bookkeeping only; the
 *     vault pays yield to the prize pot from its own treasury-funded reserve.
 *   - All vault calls are try/catch guarded so the game can never brick on
 *     vault failure.
 *
 * Security:
 *   - ReentrancyGuard on all state-changing user functions.
 *   - Escrow ring-fenced: ETH/TIMBS held here equals the sum of live +
 *     refundable ticket principal; never mingles with protocol revenue.
 *   - Only TimbPrize can drive round lifecycle (activate / settle hooks).
 *   - Emergency pause blocks new/replacement tickets; refunds & cancels
 *     always available.
 *
 * Deployment:
 *   1. Deploy GameRegistry(timbsToken, protocolSink, timbPrize?)
 *   2. setYieldVault(vault); vault.setGameRegistry(this)
 *   3. timbPrize.setGameRegistry(this)
 *   (Entry costs are dynamic — computed on-chain, no setup call.)
 */
contract GameRegistry is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Types ───────────────────────────────────────────────────────────────

    enum TicketStatus { Pending, Active, Conceded, Ineligible, Cancelled, Closed }

    struct Ticket {
        uint256      id;
        address      owner;
        bytes6       string6;           // 6-char alphanumeric entry string
        uint256      playRound;         // first round this ticket plays
        uint256      lastEligibleRound; // last round this ticket plays
        uint256      escrowAmount;      // principal held (ETH wei or TIMBS wei)
        address      escrowToken;       // address(0) = ETH, else TIMBS
        TicketStatus status;
        uint256      supersedes;        // conceded ancestor id (0 = none)
        uint256      supersededBy;      // replacement id (0 = live end of chain)
        uint256      createdAt;         // block timestamp at mint
        uint256      forfeitRound;      // round at which unclaimed escrow is swept
                                        // (§14: max of the refund-window end and,
                                        //  if the ticket won, the post-claim window)
        uint256      generation;        // game epoch this ticket was minted in
    }

    // ─── Constants ───────────────────────────────────────────────────────────

    /// @notice Cap on extra rounds per ticket — bounds the round-index loop.
    uint256 public constant MAX_EXTRA_ROUNDS = 12;

    /// @notice Principal refund window (in rounds). The 4-round forfeiture
    ///         countdown begins at the LATER of (a) the round the ticket's
    ///         eligibility ends and (b) the round its prize-claim right ends —
    ///         so a ticket that wins its last eligible round gets its full
    ///         refund window AFTER the 2-round claim closes (forfeit at LER+6),
    ///         while non-winners forfeit at LER+4. §14.
    uint256 public constant REFUND_WINDOW_ROUNDS = 4;

    /// @notice Prize-claim window mirrored from TimbPrize — a winner's claim
    ///         right runs this many rounds past the round it matched. Used to
    ///         push the forfeiture anchor when recordWinners() reports a win.
    uint256 public constant PRIZE_CLAIM_WINDOW_ROUNDS = 2;

    /// @notice Max rounds the forfeiture anchor can be pushed past
    ///         lastEligibleRound by a win (claim window + refund window).
    ///         Bounds the settlement sweep's bucket scan.
    uint256 public constant MAX_FORFEIT_PUSH = PRIZE_CLAIM_WINDOW_ROUNDS;

    /// @notice Basis-points denominator for the lapse split.
    uint256 public constant BPS = 10_000;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Community-tilted split of LAPSED ETH principal (abandoned
    ///         tickets, §14): this share is recycled into the live prize pot
    ///         (players), the remainder to the protocol sink. Lapsed TIMBS
    ///         principal routes wholly to the sink (the pot is ETH-only, and the
    ///         treasury already buys back + burns TIMBS for holders). Timelock-
    ///         set, bounded by BPS. Default 70% to the pot.
    uint256 public lapsePotBps = 7_000;

    /// @notice TIMBS token.
    IERC20 public immutable timbsToken;

    /// @notice Protocol sink (Treasury) — receives extra-round TIMBS and
    ///         absorbed escrow from claim-window-lapsed tickets.
    address public protocolSink;

    /// @notice TimbPrize — only address allowed to drive round lifecycle.
    address public timbPrize;

    /// @notice TimbYieldVault — receives active-escrow weight updates.
    address public yieldVault;

    // ─── Dynamic entry pricing (v5) ────────────────────────────────────────────
    // Entry costs are no longer static. Both are computed from live protocol
    // state, FIXED per round (predictable — what you see is what you pay), and
    // float both ways round to round:
    //
    //   ETH   = escrow ≤ 1.1 ETH → 0.001 ETH floor; else escrow / 1000
    //           (escrow = totalEthEscrow, the pot's ETH backing).
    //   TIMBS = TIMBS_ENTRY_FLOOR + activeTimbEntries × TIMBS_STEP, re-fixed only
    //           when the active TIMBS-entry count drifts ≥ 2 from the last fix
    //           (±2 deadband). Both terms are set at DEPLOY (immutable) — see
    //           the note on them below.
    //
    // Vault weight per entry is a CONSTANT unit (VAULT_WEIGHT_UNIT) — decoupled
    // from the variable cost, so yield accounting stays uniform per ticket.

    uint256 public constant ETH_ENTRY_FLOOR      = 0.001 ether; // min ETH entry cost
    uint256 public constant ETH_ESCROW_THRESHOLD = 1.1 ether;   // ≤ this → floor
    uint256 public constant ETH_SCALE_DIVISOR    = 1000;        // > threshold → escrow/1000
    uint256 public constant TIMBS_DEADBAND       = 2;           // re-fix only on ≥2 entry move

    // TIMBS entry pricing — fixed at DEPLOY, never read from the TIMBS/WETH pair
    // and never owner-settable. Deliberately a constant in the economic sense:
    // the TIMBS leg is a token-denominated price, so its ETH value drifts with
    // the market and that drift is accepted rather than tracked.
    //
    // They are immutable rather than hard-coded because the right number depends
    // on the launch price of the deployment. On a testnet where TIMBS is faucet-
    // dripped at 1/day, a floor of 2 TIMBS is right; at a mainnet launch price of
    // 1e-6 ETH/TIMBS, 2 TIMBS is ~500x cheaper than the 0.001 ETH ETH-leg floor,
    // which would push every entry onto the TIMBS leg and starve the ETH escrow
    // that funds the pot. One source, one value per deployment, no fork.
    // See dev-docs/EMISSIONS_SCHEDULE.md §7.
    uint256 public immutable TIMBS_ENTRY_FLOOR;  // TIMBS floor at zero active entries
    uint256 public immutable TIMBS_STEP;         // + this per active TIMBS entry
    // Constant ETH-denominated vault weight per active ticket. Registered as
    // ETH (address(0)) for BOTH entry tokens so every ticket carries the same
    // yield weight regardless of what it paid — decoupling yield share from the
    // variable entry cost. 1e14 wei = 0.0001 ETH matches the vault's existing
    // per-ticket parity weight, so the vault's pot-rate tuning is unchanged.
    uint256 public constant VAULT_WEIGHT_UNIT    = 1e14;

    /// @notice Live TIMBS-paid tickets in the current generation — drives the
    ///         TIMBS congestion price. Maintained at every entry/exit.
    uint256 public activeTimbEntries;

    /// @notice Sum of live ETH ticket backings (the pot's ETH escrow) — drives
    ///         the ETH price. Maintained at every ETH entry/exit.
    uint256 public totalEthEscrow;

    /// @notice Entry costs FIXED for `pricedForRound`. Held the whole round.
    uint256 public fixedEthCost;
    uint256 public fixedTimbsCost;

    /// @notice The round `fixedEthCost` / `fixedTimbsCost` apply to.
    uint256 public pricedForRound;

    /// @notice activeTimbEntries captured at the last TIMBS re-fix (deadband ref).
    uint256 public timbsPriceRefCount;

    /// @notice Current active round number (pushed by TimbPrize).
    uint256 public currentRound;

    /// @notice Current game generation (epoch). Every prize deploy runs its
    ///         one-time startGame, which bumps this via onGameStarted(). All
    ///         round-keyed state is namespaced by generation, so round N of one
    ///         game never collides with round N of the next — a prior game's
    ///         tickets go inert (not live, not eligible, no vault/forfeit
    ///         effect) and their principal is recoverable via
    ///         reclaimFromPastGame(). Starts at 1; the FIRST game keeps 1.
    uint256 public generation = 1;

    /// @dev True once any game has started. Lets the first startGame keep
    ///      generation 1 (so pre-start entries are valid) while every later
    ///      prize deploy bumps to a fresh generation.
    bool private _firstGameStarted;

    /// @notice Emergency pause — blocks new tickets; refunds always available.
    bool public paused;

    /// @notice Next ticket id (first ticket = 1; 0 = null).
    uint256 public nextTicketId = 1;

    /// @notice ticket id → ticket.
    mapping(uint256 => Ticket) public tickets;

    /// @notice wallet → its current live ticket id (0 = none).
    mapping(address => uint256) public activeTicketOf;

    /// @notice wallet → all ticket ids ever minted (history, incl. terminal).
    mapping(address => uint256[]) private _ticketsOf;

    /// @notice generation → wallet → round → the ticket id eligible for that
    ///         round. Namespaced by generation so games can't collide.
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public ticketAt;

    /// @notice generation → round → wallets with a ticket eligible that round.
    mapping(uint256 => mapping(uint256 => address[])) public roundEntrants;

    /// @notice generation → round → wallet → already in roundEntrants.
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public hasEntryInRound;

    /// @notice generation → round → string → wallets holding that string.
    ///         Stale rows (conceded/replaced) are filtered at verification.
    mapping(uint256 => mapping(uint256 => mapping(bytes6 => address[]))) public stringEntrants;

    // ─── Events ──────────────────────────────────────────────────────────────

    event TicketMinted(
        uint256 indexed ticketId,
        address indexed owner,
        bytes6  string6,
        uint256 playRound,
        uint256 lastEligibleRound,
        uint256 escrowAmount,
        address escrowToken,
        uint256 supersedes
    );
    event TicketActivated(uint256 indexed ticketId, uint256 indexed round);
    event TicketConceded(uint256 indexed oldTicketId, uint256 indexed newTicketId);
    event TicketCancelled(uint256 indexed ticketId, uint256 refundAmount, address escrowToken);
    event TicketExpired(uint256 indexed ticketId, uint256 indexed round);
    event TicketClosed(uint256 indexed ticketId, uint256 refundAmount, address escrowToken);
    event TicketIneligible(uint256 indexed ticketId, uint256 absorbedAmount, address escrowToken);
    event AdminEscrowRefunded(uint256 indexed ticketId, address indexed owner, uint256 amount, address escrowToken);
    event LapseSwept(uint256 indexed ticketId, uint256 toPot, uint256 toSink, address escrowToken);
    event LapsePotBpsSet(uint256 bps);
    event TicketForfeitExtended(uint256 indexed ticketId, uint256 indexed wonRound, uint256 newForfeitRound);
    event ExtraRoundsSunk(address indexed player, uint256 indexed ticketId, uint256 timbsAmount);
    event PricesFixed(uint256 indexed round, uint256 ethCost, uint256 timbsCost);
    event CurrentRoundUpdated(uint256 round);
    event GenerationStarted(uint256 indexed generation);
    event TicketReclaimed(uint256 indexed ticketId, uint256 amount, address escrowToken);
    event TimbPrizeSet(address indexed timbPrize);
    event ProtocolSinkSet(address indexed sink);
    event YieldVaultSet(address indexed vault);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error ContractPaused();
    error NotTimbPrize();
    error InvalidCharacter(bytes1 char);
    error RepeatingCharacter(bytes1 char);
    error ActiveTicketExists(uint256 ticketId);
    error NoLiveTicket(address player);
    error TicketNotFound(uint256 ticketId);
    error NotTicketOwner(uint256 ticketId, address caller);
    error TicketNotPending(TicketStatus status);
    error TicketNotReplaceable(TicketStatus status);
    error TicketNotRefundable(TicketStatus status);
    error TicketNotReclaimable();
    error TicketStillEligible(uint256 lastEligibleRound, uint256 currentRound);
    error ClaimWindowClosed(uint256 lastEligibleRound, uint256 currentRound);
    error RoundAlreadyStarted(uint256 playRound, uint256 currentRound);
    error WrongEscrowAmount(uint256 sent, uint256 required);
    error InsufficientAllowance(uint256 required, uint256 available);
    error TooManyExtraRounds(uint256 requested, uint256 max);
    error EthTransferFailed();
    error InvalidBps(uint256 bps);
    error InvalidTimbsPricing(uint256 floorAmount, uint256 step);

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier onlyTimbPrize() {
        if (msg.sender != timbPrize) revert NotTimbPrize();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    /// @param _timbsEntryFloor TIMBS cost of an entry at zero active TIMBS entries.
    /// @param _timbsStep        Added per active TIMBS entry. Must be ≤ the floor,
    ///        so the congestion premium can never outrun the base price per seat.
    constructor(
        address _timbsToken,
        address _protocolSink,
        address _timbPrize,
        uint256 _timbsEntryFloor,
        uint256 _timbsStep
    ) Ownable(msg.sender) {
        if (_timbsToken   == address(0)) revert ZeroAddress();
        if (_protocolSink == address(0)) revert ZeroAddress();
        if (_timbsEntryFloor == 0 || _timbsStep == 0 || _timbsStep > _timbsEntryFloor) {
            revert InvalidTimbsPricing(_timbsEntryFloor, _timbsStep);
        }
        timbsToken   = IERC20(_timbsToken);
        protocolSink = _protocolSink;
        timbPrize    = _timbPrize; // allowed address(0) at deploy
        TIMBS_ENTRY_FLOOR = _timbsEntryFloor;
        TIMBS_STEP        = _timbsStep;
    }

    // ─── String Validation ───────────────────────────────────────────────────

    /// @dev 6 chars, A-Z / 0-9 only, no repeats (bitmask over 36 symbols).
    function _validateString(bytes6 s) internal pure {
        uint64 seen = 0;
        for (uint256 i = 0; i < 6; i++) {
            bytes1 c = s[i];
            bool isUpper = c >= 0x41 && c <= 0x5A;
            bool isDigit = c >= 0x30 && c <= 0x39;
            if (!isUpper && !isDigit) revert InvalidCharacter(c);
            uint256 idx = isUpper
                ? uint256(uint8(c)) - 0x41
                : uint256(uint8(c)) - 0x30 + 26;
            uint64 bit = uint64(1 << idx);
            if (seen & bit != 0) revert RepeatingCharacter(c);
            seen |= bit;
        }
    }

    // ─── Internal: Ticket Lifecycle Helpers ──────────────────────────────────

    /// @dev True while a ticket blocks its wallet from minting another.
    ///      A prior-generation ticket is never live — a new game frees the
    ///      wallet to play, and the stranded principal is recovered via
    ///      reclaimFromPastGame().
    function _isLive(Ticket storage t) internal view returns (bool) {
        if (t.generation != generation) return false;
        if (t.status == TicketStatus.Pending) return true;
        if (t.status == TicketStatus.Active && currentRound <= t.lastEligibleRound) return true;
        return false;
    }

    /// @dev Mints a ticket and indexes it into every round it plays.
    function _mintTicket(
        address owner_,
        bytes6  string6,
        uint256 playRound,
        uint256 lastRound,
        uint256 escrowAmount,
        address escrowToken,
        uint256 supersedes
    ) internal returns (uint256 id) {
        id = nextTicketId++;
        tickets[id] = Ticket({
            id:                id,
            owner:             owner_,
            string6:           string6,
            playRound:         playRound,
            lastEligibleRound: lastRound,
            escrowAmount:      escrowAmount,
            escrowToken:       escrowToken,
            status:            TicketStatus.Pending,
            supersedes:        supersedes,
            supersededBy:      0,
            createdAt:         block.timestamp,
            // Baseline forfeiture: refund window after the last eligible round.
            // recordWinners() pushes this later if the ticket wins near the end.
            forfeitRound:      lastRound + REFUND_WINDOW_ROUNDS,
            generation:        generation
        });
        activeTicketOf[owner_] = id;
        _ticketsOf[owner_].push(id);

        uint256 g = generation;
        for (uint256 r = playRound; r <= lastRound; r++) {
            ticketAt[g][owner_][r] = id;
            stringEntrants[g][r][string6].push(owner_);
            if (!hasEntryInRound[g][r][owner_]) {
                hasEntryInRound[g][r][owner_] = true;
                roundEntrants[g][r].push(owner_);
            }
        }

        emit TicketMinted(
            id, owner_, string6, playRound, lastRound,
            escrowAmount, escrowToken, supersedes
        );
    }

    /// @dev Vault weight on — never bricks the game on vault failure.
    function _vaultRegister(uint256 ticketId, address token, uint256 amount) internal {
        if (yieldVault == address(0) || amount == 0) return;
        try ITimbYieldVaultRegistry(yieldVault).register(ticketId, token, amount) {} catch {}
    }

    /// @dev Vault weight off — idempotent, never bricks the game.
    function _vaultRemove(uint256 ticketId) internal {
        if (yieldVault == address(0)) return;
        try ITimbYieldVaultRegistry(yieldVault).remove(ticketId) {} catch {}
    }

    /// @dev Pay out ETH or TIMBS principal.
    function _payEscrow(address to, address token, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ─── Internal: Dynamic Entry Pricing (v5) ────────────────────────────────

    /// @dev ETH cost as a pure function of the pot's ETH escrow. Floats both
    ///      ways: at or below the threshold it sits on the floor; above it,
    ///      the ticket costs 1/1000 of the escrow (2 ETH escrow → 0.002 ETH).
    function _computeEthCost(uint256 escrow) internal pure returns (uint256) {
        if (escrow <= ETH_ESCROW_THRESHOLD) return ETH_ENTRY_FLOOR;
        return escrow / ETH_SCALE_DIVISOR;
    }

    /// @dev TIMBS cost as a pure function of the live TIMBS-entry count:
    ///      floor + 1 TIMBS per active TIMBS entry (2 TIMBS at zero entries).
    function _computeTimbsCost(uint256 active) internal view returns (uint256) {
        return TIMBS_ENTRY_FLOOR + active * TIMBS_STEP;
    }

    /// @dev Fix both entry costs for the round now being entered. Called on the
    ///      first entry of each play round. ETH re-prices every round off the
    ///      live escrow; TIMBS re-prices only when the active TIMBS-entry count
    ///      has drifted at least TIMBS_DEADBAND from the last fix — the deadband
    ///      keeps the TIMBS cost predictable, moving in steps, not on every seat.
    function _fixPricesForRound() internal {
        uint256 playRound = currentRound + 1;
        if (pricedForRound == playRound) return; // already fixed this round

        // ETH: always re-priced off the live escrow.
        fixedEthCost = _computeEthCost(totalEthEscrow);

        // TIMBS: re-price only outside the deadband (first fix always sets it).
        uint256 active = activeTimbEntries;
        uint256 drift  = active > timbsPriceRefCount
            ? active - timbsPriceRefCount
            : timbsPriceRefCount - active;
        if (fixedTimbsCost == 0 || drift >= TIMBS_DEADBAND) {
            fixedTimbsCost     = _computeTimbsCost(active);
            timbsPriceRefCount = active;
        }

        pricedForRound = playRound;
        emit PricesFixed(playRound, fixedEthCost, fixedTimbsCost);
    }

    /// @dev A live ticket reaches a terminal disposal (cancel / refund / forfeit
    ///      / admin-ineligible) and its seat leaves the pricing meter. Each
    ///      current-generation ticket increments the meter once at submitEntry
    ///      and reaches exactly one terminal disposal, so this decrements once —
    ///      no per-ticket flag needed. Concession (replaceEntry) carries the seat
    ///      to the replacement and must NOT call this; expiry is not terminal
    ///      (the ETH is still escrowed through the refund window). Prior-
    ///      generation tickets are skipped — onGameStarted already zeroed the
    ///      meters, so their disposal must not touch the current game's price.
    ///      Must be called BEFORE the ticket's escrowAmount is zeroed.
    function _onTicketDeactivated(Ticket storage t) internal {
        if (t.generation != generation) return;
        if (t.escrowToken == address(0)) {
            uint256 amount = t.escrowAmount;
            totalEthEscrow = amount >= totalEthEscrow ? 0 : totalEthEscrow - amount;
        } else if (activeTimbEntries > 0) {
            activeTimbEntries -= 1;
        }
    }

    // ─── Submit Entry (mint ticket) ──────────────────────────────────────────

    /**
     * @notice Mint a ticket for the next round.
     * @dev One eligible live ticket per wallet — enforced across rounds, not
     *      just per-round. Prices are fixed for the round on the first entry:
     *      ETH entries send msg.value >= the fixed ETH cost (excess refunded);
     *      TIMBS entries approve the fixed TIMBS cost first. Read the live cost
     *      via entryCostETH() / entryCostTIMBS() / nextRoundPrices() before
     *      calling. Extra rounds: TIMBS only, forfeited to the protocol sink,
     *      non-refundable.
     * @param string6     6-char entry string (A-Z / 0-9, no repeats).
     * @param useETH      True = principal in ETH, false = TIMBS.
     * @param extraRounds Rounds beyond the first (≤ MAX_EXTRA_ROUNDS).
     */
    function submitEntry(
        bytes6  string6,
        bool    useETH,
        uint256 extraRounds
    )
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (extraRounds > MAX_EXTRA_ROUNDS) {
            revert TooManyExtraRounds(extraRounds, MAX_EXTRA_ROUNDS);
        }

        // One eligible live ticket per wallet.
        uint256 liveId = activeTicketOf[msg.sender];
        if (liveId != 0 && _isLive(tickets[liveId])) {
            revert ActiveTicketExists(liveId);
        }

        _validateString(string6);

        // Fix this round's prices off live protocol state before charging.
        _fixPricesForRound();

        uint256 playRound = currentRound + 1;
        uint256 escrowAmount;
        address escrowToken;

        if (useETH) {
            uint256 ethCost = fixedEthCost;
            // `<` alone also covers the free-entry (cost 0) case correctly.
            if (msg.value < ethCost) {
                revert WrongEscrowAmount(msg.value, ethCost);
            }
            escrowAmount = ethCost;
            escrowToken  = address(0);
            if (msg.value > ethCost) {
                (bool ok,) = payable(msg.sender).call{value: msg.value - ethCost}("");
                if (!ok) revert EthTransferFailed();
            }
            totalEthEscrow += ethCost;
        } else {
            if (msg.value > 0) {
                (bool ok,) = payable(msg.sender).call{value: msg.value}("");
                if (!ok) revert EthTransferFailed();
            }
            uint256 timbsCost = fixedTimbsCost;
            escrowAmount = timbsCost;
            escrowToken  = address(timbsToken);
            timbsToken.safeTransferFrom(msg.sender, address(this), timbsCost);
            activeTimbEntries += 1;
        }

        uint256 id = _mintTicket(
            msg.sender, string6, playRound, playRound + extraRounds,
            escrowAmount, escrowToken, 0
        );

        // Extra rounds — TIMBS only, priced at this round's fixed TIMBS cost,
        // straight to the protocol sink (forfeited, non-refundable).
        uint256 additionalCost = extraRounds * fixedTimbsCost;
        if (additionalCost > 0) {
            timbsToken.safeTransferFrom(msg.sender, protocolSink, additionalCost);
            emit ExtraRoundsSunk(msg.sender, id, additionalCost);
        }
    }

    // ─── Replace Entry (concede + mint) ──────────────────────────────────────

    /**
     * @notice Replace the wallet's live ticket with a new one (same string
     *         allowed). The senior ticket becomes Conceded — visible, tethered
     *         beneath the replacement, ineligible to win. Its principal moves
     *         onto the new ticket. Extra-round TIMBS must be paid again for
     *         the replacement to carry extra rounds.
     * @param newString6  New (or same) 6-char entry string.
     * @param extraRounds Extra rounds for the NEW ticket (paid fresh in TIMBS).
     */
    function replaceEntry(bytes6 newString6, uint256 extraRounds)
        external
        nonReentrant
        whenNotPaused
    {
        uint256 oldId = activeTicketOf[msg.sender];
        if (oldId == 0) revert NoLiveTicket(msg.sender);

        Ticket storage old = tickets[oldId];
        if (!_isLive(old)) revert TicketNotReplaceable(old.status);

        if (extraRounds > MAX_EXTRA_ROUNDS) {
            revert TooManyExtraRounds(extraRounds, MAX_EXTRA_ROUNDS);
        }
        _validateString(newString6);

        // Fix this round's prices so extra rounds bill at the current TIMBS cost.
        // The replacement carries the senior ticket's principal unchanged, so the
        // pricing meters (totalEthEscrow / activeTimbEntries) are net-neutral —
        // the concession removes and the mint re-adds the same live seat.
        _fixPricesForRound();

        // Pre-flight the extra-round TIMBS pull before any state changes.
        uint256 additionalCost = extraRounds * fixedTimbsCost;
        if (additionalCost > 0) {
            uint256 allowance_ = timbsToken.allowance(msg.sender, address(this));
            if (allowance_ < additionalCost) {
                revert InsufficientAllowance(additionalCost, allowance_);
            }
        }

        // Concede the senior ticket; principal carries to the replacement.
        uint256 principal = old.escrowAmount;
        address token     = old.escrowToken;
        old.status        = TicketStatus.Conceded;
        old.escrowAmount  = 0;
        _vaultRemove(oldId);

        uint256 playRound = currentRound + 1;
        uint256 newId = _mintTicket(
            msg.sender, newString6, playRound, playRound + extraRounds,
            principal, token, oldId
        );
        old.supersededBy = newId;

        if (additionalCost > 0) {
            timbsToken.safeTransferFrom(msg.sender, protocolSink, additionalCost);
            emit ExtraRoundsSunk(msg.sender, newId, additionalCost);
        }

        emit TicketConceded(oldId, newId);
    }

    // ─── Cancel (voluntary pre-round withdrawal) ─────────────────────────────

    /**
     * @notice Cancel the wallet's Pending ticket before its round starts and
     *         reclaim the principal immediately. The ticket becomes Cancelled
     *         (no tally, ineligible) and reads as Closed once its play round
     *         begins.
     */
    function cancelEntry() external nonReentrant {
        uint256 id = activeTicketOf[msg.sender];
        if (id == 0) revert NoLiveTicket(msg.sender);

        Ticket storage t = tickets[id];
        if (t.status != TicketStatus.Pending) revert TicketNotPending(t.status);
        if (t.playRound <= currentRound) {
            revert RoundAlreadyStarted(t.playRound, currentRound);
        }

        uint256 amount = t.escrowAmount;
        address token  = t.escrowToken;
        _onTicketDeactivated(t);
        t.status       = TicketStatus.Cancelled;
        t.escrowAmount = 0;
        activeTicketOf[msg.sender] = 0;

        _payEscrow(msg.sender, token, amount);
        emit TicketCancelled(id, amount, token);
    }

    // ─── Refund (post-expiry principal withdrawal) ───────────────────────────

    /**
     * @notice Withdraw the principal of a ticket whose run has ended, within
     *         the refund window. Ticket becomes Closed (terminal, hidden).
     * @param ticketId The ticket to close.
     */
    function claimRefund(uint256 ticketId) external nonReentrant {
        Ticket storage t = tickets[ticketId];
        if (t.id == 0)               revert TicketNotFound(ticketId);
        if (t.owner != msg.sender)   revert NotTicketOwner(ticketId, msg.sender);
        // Active is the normal path; Pending covers a ticket whose activation
        // was missed (safety hatch) — both hold escrow.
        if (t.status != TicketStatus.Active && t.status != TicketStatus.Pending) {
            revert TicketNotRefundable(t.status);
        }
        if (currentRound <= t.lastEligibleRound) {
            revert TicketStillEligible(t.lastEligibleRound, currentRound);
        }
        // Refundable through forfeitRound — the later of the refund-window end
        // and (if this ticket won late) its post-claim window. §14.
        if (currentRound > t.forfeitRound) {
            revert ClaimWindowClosed(t.lastEligibleRound, currentRound);
        }

        uint256 amount = t.escrowAmount;
        address token  = t.escrowToken;
        _onTicketDeactivated(t);
        t.status       = TicketStatus.Closed;
        t.escrowAmount = 0;
        _vaultRemove(ticketId);
        if (activeTicketOf[msg.sender] == ticketId) activeTicketOf[msg.sender] = 0;

        _payEscrow(msg.sender, token, amount);
        emit TicketClosed(ticketId, amount, token);
    }

    /**
     * @notice Recover the principal of a ticket stranded by a new game epoch.
     *         When a new prize deploys and starts a game, generation bumps and
     *         every prior-generation ticket goes inert. Its round numbers no
     *         longer apply, so the normal round-window refund path can never
     *         fire — this path is round-agnostic and available immediately.
     *         Only un-terminated tickets that still hold principal qualify
     *         (Pending/Active); Conceded/Ineligible/Cancelled/Closed already
     *         had their escrow handled.
     * @param ticketId The prior-generation ticket to reclaim.
     */
    function reclaimFromPastGame(uint256 ticketId) external nonReentrant {
        Ticket storage t = tickets[ticketId];
        if (t.id == 0)                    revert TicketNotFound(ticketId);
        if (t.owner != msg.sender)        revert NotTicketOwner(ticketId, msg.sender);
        if (t.generation >= generation)   revert TicketNotReclaimable(); // still a current-game ticket
        if (t.status != TicketStatus.Active && t.status != TicketStatus.Pending) {
            revert TicketNotRefundable(t.status);
        }

        uint256 amount = t.escrowAmount;
        address token  = t.escrowToken;
        t.status       = TicketStatus.Closed;
        t.escrowAmount = 0;
        _vaultRemove(ticketId);
        if (activeTicketOf[msg.sender] == ticketId) activeTicketOf[msg.sender] = 0;

        if (amount > 0) _payEscrow(msg.sender, token, amount);
        emit TicketReclaimed(ticketId, amount, token);
    }

    // ─── TimbPrize: Round Lifecycle ──────────────────────────────────────────

    // ─── H2: paginated settlement bookkeeping ────────────────────────────────
    // Expiry + forfeiture are paginated out of the synchronous settle path so a
    // large (or sybil-flooded) entrant set can't OOG-freeze round advancement
    // (which, via refund-gating, would also lock principal). TimbPrize advances
    // the round O(1); anyone drains this afterward in bounded chunks. The cursor
    // walks a fixed ordered scan for a settled round S:
    //   [roundEntrants[S]] (expiry)  ++  [LER buckets hi, hi-1, hi-2] (forfeit).
    mapping(uint256 => mapping(uint256 => uint256)) public settleCursor; // gen → S → linear position
    mapping(uint256 => mapping(uint256 => bool))    public settleDone;   // gen → S → fully processed

    /**
     * @notice Activate Pending tickets for the CURRENT round. Registers their
     *         escrow weight in the yield vault — Active tickets earn for the pot.
     * @dev H2: permissionless + chunkable — the keeper (or anyone) activates the
     *      live round's entrants in bounded batches instead of one settle-time
     *      loop. Gated to currentRound so no future round can be pre-activated;
     *      idempotent per ticket via the Pending→Active guard below.
     */
    function activateRoundEntries(uint256 round, address[] calldata players)
        external
    {
        require(round == currentRound, "not current round");
        uint256 g = generation;
        for (uint256 i = 0; i < players.length; i++) {
            uint256 id = ticketAt[g][players[i]][round];
            if (id == 0) continue;
            Ticket storage t = tickets[id];
            if (t.status == TicketStatus.Pending && t.playRound <= round) {
                t.status = TicketStatus.Active;
                // Constant, ETH-denominated weight for every ticket — uniform
                // yield share decoupled from the variable entry cost.
                _vaultRegister(id, address(0), VAULT_WEIGHT_UNIT);
                emit TicketActivated(id, round);
            }
        }
    }

    /**
     * @notice Paginated post-settlement processing for a settled round S:
     *         1. Tickets whose run ended at S stop earning yield and free their
     *            wallet to enter again (refund window opens).
     *         2. Tickets whose refund window lapsed at S become Ineligible and
     *            their unclaimed escrow is absorbed to the protocol sink (§14).
     * @dev H2: resumable + PERMISSIONLESS. Processes up to `maxSteps` entrants
     *      per call from a stored cursor; call repeatedly until it returns true.
     *      `maxSteps == 0` means "do all remaining" (may OOG — caller's choice).
     *      Gated to already-settled rounds. The monotonic cursor visits each
     *      entrant exactly once, so the per-ticket handlers need no replay guard
     *      beyond their existing status checks. Decoupled from TimbPrize's O(1)
     *      round advancement so a large entrant set can never freeze the game.
     */
    function onRoundSettled(uint256 settledRound, uint256 maxSteps)
        external
        returns (bool done)
    {
        require(settledRound < currentRound, "round not settled");
        uint256 g = generation;
        if (settleDone[g][settledRound]) return true;
        if (maxSteps == 0) maxSteps = type(uint256).max;

        uint256 c     = settleCursor[g][settledRound];
        uint256 steps = 0;

        // Phase A — expiry over roundEntrants[S].
        address[] storage ended = roundEntrants[g][settledRound];
        uint256 nEnded = ended.length;
        while (c < nEnded && steps < maxSteps) {
            _expireOne(g, settledRound, ended[c]);
            unchecked { c++; steps++; }
        }
        if (c < nEnded) { settleCursor[g][settledRound] = c; return false; }

        // Phase B — forfeiture over LER buckets hi, hi-1, hi-2 (§14 windows).
        // Baseline LER bucket is S-4; a late win pushes forfeitRound up to LER+6,
        // so the buckets that can forfeit at S are LER in [S-6 .. S-4].
        if (settledRound > REFUND_WINDOW_ROUNDS) {
            uint256 hi = settledRound - REFUND_WINDOW_ROUNDS;
            uint256 lo = hi > MAX_FORFEIT_PUSH ? hi - MAX_FORFEIT_PUSH : 1;
            uint256 base = nEnded; // cursor offset where the forfeiture space begins
            for (uint256 ler = hi; ; ler--) {
                address[] storage bucket = roundEntrants[g][ler];
                uint256 nb = bucket.length;
                if (c < base + nb) {                       // unprocessed work in this bucket
                    uint256 i = c > base ? c - base : 0;
                    while (i < nb && steps < maxSteps) {
                        _forfeitOne(g, ler, settledRound, bucket[i]);
                        unchecked { i++; steps++; }
                    }
                    c = base + i;
                    if (i < nb) { settleCursor[g][settledRound] = c; return false; }
                }
                base += nb;
                if (ler == lo) break;                      // lo >= 1, so no underflow
            }
        }

        settleCursor[g][settledRound] = c;
        settleDone[g][settledRound]   = true;
        return true;
    }

    /// @dev Expiry of one end-of-run ticket (Phase A). Visited once via the cursor.
    function _expireOne(uint256 g, uint256 settledRound, address who) internal {
        uint256 id = ticketAt[g][who][settledRound];
        if (id == 0) return;
        Ticket storage t = tickets[id];
        if (t.status == TicketStatus.Active && t.lastEligibleRound == settledRound) {
            _vaultRemove(id);
            if (activeTicketOf[t.owner] == id) activeTicketOf[t.owner] = 0;
            emit TicketExpired(id, settledRound);
        }
    }

    /// @dev Forfeit one ticket whose forfeitRound == settledRound (Phase B). The
    ///      forfeitRound check (not LER alone) respects the §14 "later of
    ///      claim/active" anchor — a late winner is skipped until its own round.
    function _forfeitOne(uint256 g, uint256 ler, uint256 settledRound, address who) internal {
        uint256 id = ticketAt[g][who][ler];
        if (id == 0) return;
        Ticket storage t = tickets[id];
        if (t.lastEligibleRound != ler)       return;
        if (t.forfeitRound != settledRound)   return; // not due yet (won late)
        if (t.status != TicketStatus.Active &&
            t.status != TicketStatus.Pending) return; // already refunded/terminal

        uint256 amount = t.escrowAmount;
        address token  = t.escrowToken;
        _onTicketDeactivated(t);
        t.status = TicketStatus.Ineligible;
        _vaultRemove(id);
        if (activeTicketOf[t.owner] == id) activeTicketOf[t.owner] = 0;

        if (amount > 0) {
            if (token == address(0)) {
                // Community-tilted recycle (abandoned-ticket revenue): a share of
                // lapsed ETH flows back into the live prize pot (players), the
                // rest to the protocol sink. Both legs are best-effort and the
                // escrow is decremented only by what actually left, so a failing
                // leg neither blocks the settlement loop nor double-spends on a
                // later retry (whatever couldn't be disposed stays on the ticket).
                uint256 toPot   = 0;
                uint256 potShare = (amount * lapsePotBps) / BPS;
                if (potShare > 0 && timbPrize != address(0)) {
                    try ITimbPrizePot(timbPrize).addToPot{value: potShare}() {
                        toPot = potShare;
                    } catch {
                        // pot leg failed → the whole amount falls to the sink
                    }
                }
                uint256 toSink = amount - toPot;
                uint256 leftover = 0;
                if (toSink > 0) {
                    (bool ok,) = payable(protocolSink).call{value: toSink}("");
                    if (!ok) { leftover = toSink; toSink = 0; }
                }
                t.escrowAmount = leftover;
                emit LapseSwept(id, toPot, toSink, token);
            } else {
                // Lapsed TIMBS → sink (treasury buys back + burns for holders).
                t.escrowAmount = 0;
                IERC20(token).safeTransfer(protocolSink, amount);
                emit LapseSwept(id, 0, amount, token);
            }
        }
        emit TicketIneligible(id, amount, token);
    }

    /// @notice TimbPrize reports the winners of a settled round so the registry
    ///         can push their forfeiture anchor past the prize-claim window —
    ///         a winner's principal refund window starts only once the claim
    ///         right is also over (§14). Idempotent and monotonic: forfeitRound
    ///         only ever moves later, and settlement calls this in round order.
    function recordWinners(uint256 round, address[] calldata winners) external onlyTimbPrize {
        uint256 pushed = round + PRIZE_CLAIM_WINDOW_ROUNDS + REFUND_WINDOW_ROUNDS;
        for (uint256 i = 0; i < winners.length; i++) {
            uint256 id = ticketAt[generation][winners[i]][round];
            if (id == 0) continue;
            Ticket storage t = tickets[id];
            if (pushed > t.forfeitRound) {
                t.forfeitRound = pushed;
                emit TicketForfeitExtended(id, round, pushed);
            }
        }
    }

    /// @notice Update current round number — called by TimbPrize at round start.
    function setCurrentRound(uint256 round) external onlyTimbPrize {
        currentRound = round;
        emit CurrentRoundUpdated(round);
    }

    /// @notice Begin a new game epoch — called once by each TimbPrize at its
    ///         startGame. The first game ever keeps generation 1 (so any
    ///         pre-start entries stay valid); every later prize deploy bumps to
    ///         a fresh generation, retiring the prior game's tickets from all
    ///         round-keyed state without any unbounded loop. Also resets the
    ///         round to 1.
    function onGameStarted() external onlyTimbPrize {
        if (_firstGameStarted) {
            generation += 1;
        } else {
            _firstGameStarted = true;
        }
        currentRound = 1;

        // Reset the dynamic-pricing meters for the fresh generation. Prior-game
        // seats belong to the retired generation and no longer back the price;
        // _onTicketDeactivated skips them, so clearing here can't underflow.
        activeTimbEntries  = 0;
        totalEthEscrow     = 0;
        timbsPriceRefCount = 0;
        fixedTimbsCost     = 0;
        fixedEthCost       = 0;
        pricedForRound     = 0;

        emit GenerationStarted(generation);
        emit CurrentRoundUpdated(1);
    }

    // ─── Dual-Layer Verification (TimbPrize settlement) ──────────────────────

    /// @notice Layer 1: a ticket existed for this player and round.
    function verifyEntryExisted(address player, uint256 round)
        external
        view
        returns (bool exists, bytes6 string6)
    {
        uint256 id = ticketAt[generation][player][round];
        if (id == 0) return (false, bytes6(0));
        return (true, tickets[id].string6);
    }

    /// @notice Layer 2: the ticket is live (Active, or Pending once its play
    ///         round has started) and eligible for this round.
    /// @dev    Activation is a permissionless keeper step that only registers
    ///         yield weight. Prize eligibility must not depend on it: if a
    ///         matching ticket were still Pending at settlement (keeper
    ///         lagging), anyone could activate only their own ticket and take
    ///         the omitted winners' shares (TS-008). A Pending ticket whose
    ///         playRound has arrived is therefore a valid entry here.
    function verifyEntryValid(address player, uint256 round)
        external
        view
        returns (bool valid, bytes6 string6)
    {
        uint256 id = ticketAt[generation][player][round];
        if (id == 0) return (false, bytes6(0));
        Ticket storage t = tickets[id];
        if (t.status != TicketStatus.Active && t.status != TicketStatus.Pending) return (false, bytes6(0));
        if (round < t.playRound || round > t.lastEligibleRound)    return (false, bytes6(0));
        return (true, t.string6);
    }

    /// @notice Wallets holding a given string for a round (raw; settlement
    ///         applies the dual-layer filter over this list).
    function getStringEntrants(uint256 round, bytes6 string6)
        external
        view
        returns (address[] memory)
    {
        return stringEntrants[generation][round][string6];
    }

    /// @notice Wallets with a ticket eligible in a round.
    function getRoundEntrants(uint256 round)
        external
        view
        returns (address[] memory)
    {
        return roundEntrants[generation][round];
    }

    // ─── Views: Tickets ──────────────────────────────────────────────────────

    /**
     * @notice Status as it should be displayed: Cancelled reads as Closed
     *         once its play round has begun (settlement rolled the round).
     */
    function effectiveStatus(uint256 ticketId) public view returns (TicketStatus) {
        Ticket storage t = tickets[ticketId];
        if (t.status == TicketStatus.Cancelled && currentRound >= t.playRound) {
            return TicketStatus.Closed;
        }
        return t.status;
    }

    /// @notice One ticket + its display status.
    function getTicket(uint256 ticketId)
        external
        view
        returns (Ticket memory t, TicketStatus displayStatus)
    {
        t = tickets[ticketId];
        if (t.id == 0) revert TicketNotFound(ticketId);
        displayStatus = effectiveStatus(ticketId);
    }

    /// @notice Every ticket a wallet has ever minted, with display statuses.
    function getTicketsOf(address owner_)
        external
        view
        returns (Ticket[] memory list, TicketStatus[] memory displayStatuses)
    {
        uint256[] storage ids = _ticketsOf[owner_];
        list            = new Ticket[](ids.length);
        displayStatuses = new TicketStatus[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            list[i]            = tickets[ids[i]];
            displayStatuses[i] = effectiveStatus(ids[i]);
        }
    }

    /// @notice Conceded ancestry of a ticket, newest → oldest.
    function getTicketChain(uint256 ticketId)
        external
        view
        returns (uint256[] memory ancestors)
    {
        // Count first (chain is bounded by replacements made; hard cap 64).
        uint256 count;
        uint256 cursor = tickets[ticketId].supersedes;
        while (cursor != 0 && count < 64) { count++; cursor = tickets[cursor].supersedes; }

        ancestors = new uint256[](count);
        cursor = tickets[ticketId].supersedes;
        for (uint256 i = 0; i < count; i++) {
            ancestors[i] = cursor;
            cursor = tickets[cursor].supersedes;
        }
    }

    /// @notice Identical-string count for the next round (collision display).
    function getIdenticalCount(bytes6 string6) external view returns (uint256) {
        return stringEntrants[generation][currentRound + 1][string6].length;
    }

    /// @notice Extra-round cost helper — priced at the next round's TIMBS cost.
    function additionalRoundCost(uint256 extraRounds) external view returns (uint256) {
        (, uint256 timbsCost) = _previewPrices();
        return extraRounds * timbsCost;
    }

    // ─── Views: Dynamic Entry Pricing (v5) ───────────────────────────────────

    /// @dev What the next entry would pay. If this round's prices are already
    ///      locked (first entry has fixed them), returns the locked pair;
    ///      otherwise previews the fix off live state — mirrors
    ///      _fixPricesForRound exactly, without mutating.
    function _previewPrices() internal view returns (uint256 ethCost, uint256 timbsCost) {
        if (pricedForRound == currentRound + 1) {
            return (fixedEthCost, fixedTimbsCost);
        }
        ethCost = _computeEthCost(totalEthEscrow);
        uint256 active = activeTimbEntries;
        uint256 drift  = active > timbsPriceRefCount
            ? active - timbsPriceRefCount
            : timbsPriceRefCount - active;
        timbsCost = (fixedTimbsCost == 0 || drift >= TIMBS_DEADBAND)
            ? _computeTimbsCost(active)
            : fixedTimbsCost;
    }

    /// @notice Current ETH entry cost (what the next entry pays). Preserves the
    ///         pre-v5 ABI so any caller reading entryCostETH() keeps working.
    function entryCostETH() external view returns (uint256 ethCost) {
        (ethCost, ) = _previewPrices();
    }

    /// @notice Current TIMBS entry cost (what the next entry pays). ABI-
    ///         compatible with the pre-v5 public getter.
    function entryCostTIMBS() external view returns (uint256 timbsCost) {
        (, timbsCost) = _previewPrices();
    }

    /// @notice Telegraph both next-round entry costs in one call, so the UI can
    ///         show players exactly what they'll pay before they commit.
    function nextRoundPrices() external view returns (uint256 ethCost, uint256 timbsCost) {
        return _previewPrices();
    }

    // ─── Owner: Config ───────────────────────────────────────────────────────

    // Entry costs are fully dynamic in v5 (computed from live protocol state and
    // fixed per round) — there is no governance setter. The pricing constants
    // (floors, threshold, divisor, deadband) are compile-time and immutable.

    function setTimbPrize(address _timbPrize) external onlyOwner {
        if (_timbPrize == address(0)) revert ZeroAddress();
        timbPrize = _timbPrize;
        emit TimbPrizeSet(_timbPrize);
    }

    function setProtocolSink(address _sink) external onlyOwner {
        if (_sink == address(0)) revert ZeroAddress();
        protocolSink = _sink;
        emit ProtocolSinkSet(_sink);
    }

    /// @notice Set the share of LAPSED ETH principal recycled to the prize pot
    ///         (basis points; remainder goes to the protocol sink). Timelock-set.
    function setLapsePotBps(uint256 _bps) external onlyOwner {
        if (_bps > BPS) revert InvalidBps(_bps);
        lapsePotBps = _bps;
        emit LapsePotBpsSet(_bps);
    }

    function setYieldVault(address _vault) external onlyOwner {
        yieldVault = _vault; // address(0) allowed = yield disabled
        emit YieldVaultSet(_vault);
    }

    /// @notice Escape hatch for a ticket/game inconsistency ("contract error
    ///         between ticket and game") — flags the ticket Ineligible.
    ///         Escrow stays on the ticket for a follow-up adminRefundStuck
    ///         or the player's own claim path.
    /// @dev M3: this only changes a ticket's STATUS and releases its pricing
    ///      seat. It moves no funds and can never route escrow anywhere but back
    ///      to the ticket owner (see adminRefundStuck), so it is not a
    ///      confiscation surface.
    function adminMarkIneligible(uint256 ticketId) external onlyOwner {
        Ticket storage t = tickets[ticketId];
        if (t.id == 0) revert TicketNotFound(ticketId);
        // Only a still-counted (Pending/Active) ticket owns a live pricing seat;
        // release it once. Re-flagging an already-terminal ticket must not touch
        // the meter.
        if (t.status == TicketStatus.Pending || t.status == TicketStatus.Active) {
            _onTicketDeactivated(t);
        }
        t.status = TicketStatus.Ineligible;
        _vaultRemove(ticketId);
        if (activeTicketOf[t.owner] == ticketId) activeTicketOf[t.owner] = 0;
        emit TicketIneligible(ticketId, t.escrowAmount, t.escrowToken);
    }

    /// @notice Return escrow stranded on an Ineligible ticket to the TICKET
    ///         OWNER (e.g. a ticket/game inconsistency, or an ETH send that
    ///         failed during settlement).
    /// @dev M3: this used to sweep the escrow to `protocolSink`, which let the
    ///      owner mark any live ticket Ineligible and confiscate a player's
    ///      stake. The destination is now hard-wired to `t.owner`, so the admin
    ///      path can only ever REFUND the player, never seize funds — the owner
    ///      gains nothing from misusing it. Legitimate forfeiture of a
    ///      claim-window-lapsed ticket to the sink still happens automatically
    ///      in the §14 settlement sweep, which this does not touch.
    function adminRefundStuck(uint256 ticketId) external onlyOwner nonReentrant {
        Ticket storage t = tickets[ticketId];
        if (t.id == 0) revert TicketNotFound(ticketId);
        if (t.status != TicketStatus.Ineligible) revert TicketNotRefundable(t.status);
        uint256 amount = t.escrowAmount;
        if (amount == 0) revert ZeroAmount();
        address token = t.escrowToken;
        address to    = t.owner;
        t.escrowAmount = 0;
        _payEscrow(to, token, amount);
        emit AdminEscrowRefunded(ticketId, to, amount, token);
    }

    function pause()   external onlyOwner { paused = true;  emit Paused(msg.sender); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(msg.sender); }
}
