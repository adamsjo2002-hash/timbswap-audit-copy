// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TimbYieldVault
 * @notice Internal, treasury-funded yield engine for the prize game
 *         (PoolTogether-inspired, fully self-contained on Arbitrum Sepolia).
 *
 * Model:
 *   - Active tickets' escrow is counted here as WEIGHT ONLY — the principal
 *     itself never leaves GameRegistry's ring-fence and can never be lost
 *     through this contract.
 *   - While weight is registered, yield accrues per-second, proportional to
 *     total weight, and is CAPPED by this contract's funded reserve. If the
 *     reserve runs dry, accrual simply pauses — principal is never touched.
 *   - Accrued yield goes to ONE destination: the prize pot. Depositors get
 *     their principal back plus a chance at the pot — never the yield
 *     directly. That's what keeps it a lottery, not a savings account.
 *   - Funded by the Treasury / owner from protocol fee revenue (fund() or a
 *     plain ETH send). Rate is governance-set.
 *
 * Weight denomination:
 *   ETH escrow counts 1:1. TIMBS escrow converts via timbsWeight1e18
 *   (weight wei per TIMBS wei, 1e18-scaled) so both entry tokens earn for
 *   the pot on a comparable basis.
 *
 * Harvest:
 *   TimbPrize pulls all accrued yield at each round settlement, adds it to
 *   currentAccumulatedRewards, and forwards the ETH into PrizeEscrow — the
 *   4th pot source alongside swap fees, seeding, and the snowball remainder.
 *
 * Security:
 *   - register/remove only from GameRegistry; harvest only from TimbPrize.
 *   - Failed harvest transfer restores state and returns 0 — settlement can
 *     never brick on this contract.
 *   - No user funds held here, ever: emergencyWithdraw only moves the
 *     protocol's own subsidy reserve.
 *
 * Deployment:
 *   1. Deploy TimbYieldVault()
 *   2. setGameRegistry(registry); setTimbPrize(prize)
 *   3. setTimbsWeight1e18(1e11)          // 1000 TIMBS ≙ 0.0001 ETH weight
 *   4. setYieldAPRBps(1000)              // e.g. 10% APR on active escrow
 *   5. fund() with ETH from the Treasury
 */
contract TimbYieldVault is Ownable, ReentrancyGuard {

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice GameRegistry — only caller for register()/remove().
    address public gameRegistry;

    /// @notice TimbPrize — only caller for harvest().
    address public timbPrize;

    /// @notice Sum of registered ticket weight (ETH-denominated wei).
    uint256 public totalWeight;

    /// @notice ticket id → registered weight.
    mapping(uint256 => uint256) public weightOf;

    /// @notice Pot wei generated per 1e18 weight per second.
    uint256 public ratePerSecond1e18;

    /// @notice Weight wei per TIMBS wei, 1e18-scaled
    ///         (weight = timbsAmount * timbsWeight1e18 / 1e18).
    uint256 public timbsWeight1e18;

    /// @notice Yield accrued and earmarked for the pot, awaiting harvest.
    uint256 public accruedForPot;

    /// @notice Last accrual timestamp.
    uint256 public lastAccrual;

    // ─── Events ──────────────────────────────────────────────────────────────

    event WeightRegistered(uint256 indexed ticketId, uint256 weight, uint256 totalWeight);
    event WeightRemoved(uint256 indexed ticketId, uint256 weight, uint256 totalWeight);
    event YieldAccrued(uint256 amount, uint256 accruedForPot);
    event Harvested(uint256 amount, address indexed to);
    event Funded(address indexed from, uint256 amount);
    event RateSet(uint256 ratePerSecond1e18);
    event TimbsWeightSet(uint256 timbsWeight1e18);
    event GameRegistrySet(address indexed registry);
    event TimbPrizeSet(address indexed prize);
    event EmergencyWithdrawn(address indexed to, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error NotGameRegistry();
    error NotTimbPrize();
    error InsufficientReserve(uint256 requested, uint256 available);

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyGameRegistry() {
        if (msg.sender != gameRegistry) revert NotGameRegistry();
        _;
    }

    modifier onlyTimbPrize() {
        if (msg.sender != timbPrize) revert NotTimbPrize();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor() Ownable(msg.sender) {
        lastAccrual = block.timestamp;
    }

    // ─── Accrual ─────────────────────────────────────────────────────────────

    /// @notice ETH available to back future accrual (not yet earmarked).
    function reserve() public view returns (uint256) {
        return address(this).balance - accruedForPot;
    }

    /// @dev Accrue since last touch: totalWeight × rate × elapsed, capped by
    ///      the funded reserve. Reserve dry ⇒ accrual pauses; principal is
    ///      never involved (it isn't even held here).
    function _accrue() internal {
        uint256 elapsed = block.timestamp - lastAccrual;
        if (elapsed == 0) return;
        lastAccrual = block.timestamp;

        if (totalWeight == 0 || ratePerSecond1e18 == 0) return;

        uint256 pending = (totalWeight * ratePerSecond1e18 / 1e18) * elapsed;
        uint256 available = address(this).balance - accruedForPot;
        if (pending > available) pending = available;
        if (pending == 0) return;

        accruedForPot += pending;
        emit YieldAccrued(pending, accruedForPot);
    }

    /// @notice Accrued-so-far including live (unstored) accrual — for UI.
    function previewAccrued() external view returns (uint256) {
        uint256 pending = 0;
        if (totalWeight > 0 && ratePerSecond1e18 > 0) {
            pending = (totalWeight * ratePerSecond1e18 / 1e18)
                * (block.timestamp - lastAccrual);
            uint256 available = address(this).balance - accruedForPot;
            if (pending > available) pending = available;
        }
        return accruedForPot + pending;
    }

    // ─── GameRegistry: Weight ────────────────────────────────────────────────

    /**
     * @notice Register an activated ticket's escrow weight. Idempotent per id.
     * @param ticketId Ticket id (from GameRegistry).
     * @param token    Escrow token — address(0) = ETH.
     * @param amount   Escrow amount (wei of its token).
     */
    function register(uint256 ticketId, address token, uint256 amount)
        external
        onlyGameRegistry
    {
        if (weightOf[ticketId] != 0) return; // already registered
        _accrue();

        uint256 w = token == address(0)
            ? amount
            : amount * timbsWeight1e18 / 1e18;
        if (w == 0) return;

        weightOf[ticketId] = w;
        totalWeight += w;
        emit WeightRegistered(ticketId, w, totalWeight);
    }

    /// @notice Remove a ticket's weight (exited Active). Idempotent.
    function remove(uint256 ticketId) external onlyGameRegistry {
        uint256 w = weightOf[ticketId];
        if (w == 0) return;
        _accrue();

        delete weightOf[ticketId];
        totalWeight -= w;
        emit WeightRemoved(ticketId, w, totalWeight);
    }

    // ─── TimbPrize: Harvest ──────────────────────────────────────────────────

    /**
     * @notice Pull all accrued yield to TimbPrize (round settlement).
     * @dev On transfer failure, state is restored and 0 returned — the
     *      settlement transaction never bricks on this contract.
     * @return amount ETH wei sent to TimbPrize for the pot.
     */
    function harvest() external nonReentrant onlyTimbPrize returns (uint256 amount) {
        _accrue();
        amount = accruedForPot;
        if (amount == 0) return 0;

        accruedForPot = 0;
        (bool ok,) = payable(timbPrize).call{value: amount}("");
        if (!ok) {
            accruedForPot = amount;
            return 0;
        }
        emit Harvested(amount, timbPrize);
    }

    // ─── Funding ─────────────────────────────────────────────────────────────

    /// @notice Top up the yield reserve (Treasury / owner / anyone).
    function fund() external payable {
        if (msg.value == 0) revert ZeroAmount();
        emit Funded(msg.sender, msg.value);
    }

    receive() external payable {
        if (msg.value > 0) emit Funded(msg.sender, msg.value);
    }

    // ─── Owner: Config ───────────────────────────────────────────────────────

    function setGameRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert ZeroAddress();
        gameRegistry = _registry;
        emit GameRegistrySet(_registry);
    }

    function setTimbPrize(address _prize) external onlyOwner {
        if (_prize == address(0)) revert ZeroAddress();
        timbPrize = _prize;
        emit TimbPrizeSet(_prize);
    }

    /// @notice Raw rate: pot wei per 1e18 weight per second.
    function setRatePerSecond(uint256 _rate1e18) external onlyOwner {
        _accrue(); // settle at the old rate first
        ratePerSecond1e18 = _rate1e18;
        emit RateSet(_rate1e18);
    }

    /// @notice Convenience: set the rate as an APR in basis points
    ///         (1000 = 10% of active escrow per year flows to the pot).
    function setYieldAPRBps(uint256 aprBps) external onlyOwner {
        _accrue();
        ratePerSecond1e18 = aprBps * 1e18 / 10_000 / 365 days;
        emit RateSet(ratePerSecond1e18);
    }

    /// @notice ETH-weight per TIMBS (1e18-scaled). E.g. 1e11 makes
    ///         1000 TIMBS ≙ 0.0001 ETH of weight (entry-cost parity).
    function setTimbsWeight1e18(uint256 _w) external onlyOwner {
        _accrue();
        timbsWeight1e18 = _w;
        emit TimbsWeightSet(_w);
    }

    /// @notice Withdraw un-earmarked reserve — protocol subsidy money only;
    ///         no user principal is ever held in this contract.
    function emergencyWithdraw(address to, uint256 amount)
        external
        nonReentrant
        onlyOwner
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0)      revert ZeroAmount();
        uint256 available = address(this).balance - accruedForPot;
        if (amount > available) revert InsufficientReserve(amount, available);
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert ZeroAmount();
        emit EmergencyWithdrawn(to, amount);
    }
}
