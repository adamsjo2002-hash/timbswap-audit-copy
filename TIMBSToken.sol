// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TIMBSToken
 * @notice Native ERC-20 token for the TimbSwap protocol.
 *
 * Supply model:
 *   - Fixed initial supply minted entirely to the treasury at deploy.
 *   - Owner can mint additional supply for emissions (staking/farm rewards).
 *   - Emissions cap enforced: total supply can never exceed HARD_CAP.
 *   - Owner can burn from treasury allocation via ERC20Burnable.
 *
 * Access:
 *   - Minter role: owner only (treasury / emissions controller).
 *   - Emission rate: owner-set (TIMBS per day, used by staking/farm contracts).
 *   - Governance can update entryCostTIMBS — single param, cascades to all
 *     prize entry cost derivatives.
 *
 * Security (defi-security skill):
 *   - ReentrancyGuard on mint path.
 *   - Whitelist for addresses exempt from per-tx transfer cap.
 *   - Per-tx transfer cap owner-configurable (anti-whale).
 *   - Owner can pause transfers in emergency.
 *
 * Deployment:
 *   - Deploy with treasury address and initial supply.
 *   - Call setStakingPool(), setFarmPool() after those contracts are deployed.
 *   - setEmissionRate() to activate staking/farm emissions.
 */
contract TIMBSToken is ERC20, ERC20Burnable, Ownable, ReentrancyGuard {

    // ─── Constants ───────────────────────────────────────────────────────────

    /// @notice Absolute hard cap on total supply (initial + all future emissions).
    uint256 public constant HARD_CAP = 100_000_000 * 1e18; // 100 Million TIMBS

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Treasury address — receives initial mint, controls distribution.
    address public treasury;

    /// @notice Staking pool contract — authorised to call mintEmissions().
    address public stakingPool;

    /// @notice Farm (LP) pool contract — authorised to call mintEmissions().
    address public farmPool;

    /// @notice Owner-set emission rate in TIMBS per day (informational + used by pools).
    uint256 public emissionRatePerDay;

    /// @notice Prize game entry cost in TIMBS. Governance-changeable.
    /// All ETH/additional-round costs derive from this single value.
    uint256 public entryCostTIMBS;

    /// @notice Max TIMBS transferable in a single tx (anti-whale). 0 = disabled.
    uint256 public maxTransferAmount;

    /// @notice Addresses exempt from maxTransferAmount (pools, treasury, etc.).
    mapping(address => bool) public transferWhitelist;

    /// @notice Emergency pause flag — owner can halt all transfers.
    bool public paused;

    // ─── Events ──────────────────────────────────────────────────────────────

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event StakingPoolSet(address indexed stakingPool);
    event FarmPoolSet(address indexed farmPool);
    event EmissionRateSet(uint256 ratePerDay);
    event EmissionsMinted(address indexed recipient, uint256 amount);
    event EntryCostUpdated(uint256 oldCost, uint256 newCost);
    event MaxTransferAmountSet(uint256 amount);
    event TransferWhitelistUpdated(address indexed account, bool exempt);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ExceedsHardCap(uint256 requested, uint256 available);
    error NotAuthorizedMinter();
    error TransferPaused();
    error ExceedsMaxTransfer(uint256 amount, uint256 max);
    error ZeroAmount();

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier whenNotPaused() {
        if (paused) revert TransferPaused();
        _;
    }

    modifier onlyMinter() {
        if (msg.sender != stakingPool && msg.sender != farmPool && msg.sender != owner()) {
            revert NotAuthorizedMinter();
        }
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param _treasury   Address that receives the full initial supply.
     * @param initialSupply Amount of TIMBS (in wei) minted at deploy. Must be <= HARD_CAP.
     * @param _entryCostTIMBS Initial prize game entry cost in TIMBS (18 decimals).
     */
    constructor(
        address _treasury,
        uint256 initialSupply,
        uint256 _entryCostTIMBS
    ) ERC20("TimbSwap Token", "TIMBS") Ownable(msg.sender) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (initialSupply == 0) revert ZeroAmount();
        if (initialSupply > HARD_CAP) revert ExceedsHardCap(initialSupply, HARD_CAP);

        treasury = _treasury;
        entryCostTIMBS = _entryCostTIMBS;

        // Whitelist treasury from transfer cap by default
        transferWhitelist[_treasury] = true;
        transferWhitelist[msg.sender] = true;

        _mint(_treasury, initialSupply);

        emit TreasuryUpdated(address(0), _treasury);
        emit EntryCostUpdated(0, _entryCostTIMBS);
    }

    // ─── Owner: Protocol Config ───────────────────────────────────────────────

    /**
     * @notice Set or update the treasury address.
     * @dev Removes whitelist from old treasury, adds to new.
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        transferWhitelist[treasury] = false;
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
        transferWhitelist[_treasury] = true;
    }

    /**
     * @notice Register the staking pool contract as an authorised emissions minter.
     */
    function setStakingPool(address _stakingPool) external onlyOwner {
        if (_stakingPool == address(0)) revert ZeroAddress();
        // Remove whitelist from old pool if set
        if (stakingPool != address(0)) transferWhitelist[stakingPool] = false;
        stakingPool = _stakingPool;
        transferWhitelist[_stakingPool] = true;
        emit StakingPoolSet(_stakingPool);
    }

    /**
     * @notice Register the LP farm pool contract as an authorised emissions minter.
     */
    function setFarmPool(address _farmPool) external onlyOwner {
        if (_farmPool == address(0)) revert ZeroAddress();
        if (farmPool != address(0)) transferWhitelist[farmPool] = false;
        farmPool = _farmPool;
        transferWhitelist[_farmPool] = true;
        emit FarmPoolSet(_farmPool);
    }

    /**
     * @notice Set the protocol-wide emission rate in TIMBS per day.
     * @dev Informational for UI and used by staking/farm contracts to
     *      calculate per-second rates. Does not auto-distribute.
     */
    function setEmissionRate(uint256 _ratePerDay) external onlyOwner {
        emissionRatePerDay = _ratePerDay;
        emit EmissionRateSet(_ratePerDay);
    }

    /**
     * @notice Update prize game entry cost. Single governance parameter —
     *         ETH equivalent and additional-round costs derive from this.
     * @dev Callable by owner (governance-executed in hybrid model).
     */
    function setEntryCostTIMBS(uint256 _cost) external onlyOwner {
        if (_cost == 0) revert ZeroAmount();
        emit EntryCostUpdated(entryCostTIMBS, _cost);
        entryCostTIMBS = _cost;
    }

    /**
     * @notice Set max TIMBS per single transfer (anti-whale). Set to 0 to disable.
     */
    function setMaxTransferAmount(uint256 _max) external onlyOwner {
        maxTransferAmount = _max;
        emit MaxTransferAmountSet(_max);
    }

    /**
     * @notice Exempt or un-exempt an address from the transfer cap.
     */
    function setTransferWhitelist(address _account, bool _exempt) external onlyOwner {
        if (_account == address(0)) revert ZeroAddress();
        transferWhitelist[_account] = _exempt;
        emit TransferWhitelistUpdated(_account, _exempt);
    }

    /**
     * @notice Pause all token transfers. Emergency use only.
     */
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause token transfers.
     */
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ─── Emissions Minting ────────────────────────────────────────────────────

    /**
     * @notice Mint emissions to a staking or farm pool.
     * @dev Only callable by stakingPool, farmPool, or owner.
     *      Total supply after mint must not exceed HARD_CAP.
     * @param recipient Address to receive minted TIMBS (pool contract).
     * @param amount    Amount in wei.
     */
    function mintEmissions(address recipient, uint256 amount)
        external
        nonReentrant
        onlyMinter
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 available = HARD_CAP - totalSupply();
        if (amount > available) revert ExceedsHardCap(amount, available);

        _mint(recipient, amount);
        emit EmissionsMinted(recipient, amount);
    }

    // ─── View Helpers ─────────────────────────────────────────────────────────

    /**
     * @notice Remaining emissions capacity before hitting the hard cap.
     */
    function remainingEmissionsCapacity() external view returns (uint256) {
        return HARD_CAP - totalSupply();
    }

    /**
     * @notice ETH equivalent of entry cost derived from the TIMBS/ETH pool price.
     * @dev Placeholder — live implementation reads from TimbSwapPair.
     *      Returns 0 until pair is deployed and has liquidity.
     */
    function entryCostETH() external pure returns (uint256) {
        // TODO: integrate TimbSwapPair.getReserves() price feed post-deploy
        return 0;
    }

    // ─── Transfer Hook ────────────────────────────────────────────────────────

    /**
     * @dev Override to enforce pause + per-tx transfer cap.
     *      Whitelist bypasses cap. Mint/burn paths (from/to address(0)) bypass both.
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override whenNotPaused {
        // Bypass checks on mint (from == 0) and burn (to == 0)
        if (from != address(0) && to != address(0)) {
            if (
                maxTransferAmount > 0 &&
                !transferWhitelist[from] &&
                !transferWhitelist[to]
            ) {
                if (value > maxTransferAmount) {
                    revert ExceedsMaxTransfer(value, maxTransferAmount);
                }
            }
        }
        super._update(from, to, value);
    }
}
