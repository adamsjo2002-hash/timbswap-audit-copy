// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TimbStaking
 * @notice Single-asset TIMBS staking pool.
 *
 * Model:
 *   - Stake TIMBS, earn TIMBS distributions.
 *   - Reward source: treasury-seeded allocation + buyback distributions
 *     sent by TimbTreasury after each buyback execution.
 *   - Fixed APR set by owner (changeable anytime).
 *   - Rewards accrue per-second proportional to staker's share.
 *   - No unique stake IDs — single accumulated balance per address.
 *   - Free add/reduce/withdraw anytime — no lock, no penalty.
 *
 * Reward calculation (MasterChef-style rewardPerToken accumulator):
 *   rewardPerTokenStored tracks cumulative TIMBS earned per staked TIMBS.
 *   On every interaction, pending rewards are snapshotted for the user.
 *   This avoids looping over stakers and scales to any number of users.
 *
 * Security (defiSKILL):
 *   - ReentrancyGuard on stake(), unstake(), claimRewards().
 *   - Collateral ownership: all functions verify msg.sender owns the stake
 *     (no delegate staking without explicit approval).
 *   - Flash loan protection: reward accrual uses time-weighted accumulator,
 *     not spot balance — flash staking earns nothing meaningful.
 *   - SafeERC20 on all token transfers.
 *   - Emergency pause on stake/unstake/claim.
 *   - notifyRewardAmount() restricted to owner + treasury (authorised callers).
 *
 * Deployment:
 *   1. Deploy TimbStaking(timbsToken, rewardRatePerSecond)
 *   2. TIMBSToken.setStakingPool(address(this))
 *   3. Fund with initial TIMBS reward allocation from treasury
 *   4. TimbTreasury.setStakingPool(address(this)) for buyback distributions
 */
contract TimbStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice TIMBS token — staked and earned.
    IERC20 public immutable timbsToken;

    /// @notice TimbTreasury — authorised to call notifyRewardAmount().
    address public treasury;

    /// @notice TIMBS rewards distributed per second across all stakers.
    ///         Owner-set. Changing mid-period snapshots the current accumulator.
    uint256 public rewardRatePerSecond;

    /// @notice Timestamp when current reward period ends.
    uint256 public periodFinish;

    /// @notice Last timestamp rewardPerTokenStored was updated.
    uint256 public lastUpdateTime;

    /// @notice Cumulative TIMBS earned per staked TIMBS (18-decimal fixed point).
    uint256 public rewardPerTokenStored;

    /// @notice Total TIMBS currently staked across all users.
    uint256 public totalStaked;

    /// @notice Staked balance per address.
    mapping(address => uint256) public stakedBalance;

    /// @notice Snapshot of rewardPerTokenStored when user last interacted.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Pending (earned but unclaimed) rewards per address.
    mapping(address => uint256) public pendingRewards;

    /// @notice Addresses authorised to call notifyRewardAmount()
    ///         (owner + treasury).
    mapping(address => bool) public rewardNotifiers;

    /// @notice Emergency pause flag.
    bool public paused;

    // ─── Events ──────────────────────────────────────────────────────────────

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardNotified(address indexed notifier, uint256 amount, uint256 duration);
    event RewardRateSet(uint256 newRatePerSecond);
    event TreasurySet(address indexed treasury);
    event RewardNotifierSet(address indexed notifier, bool authorised);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event EmergencyWithdraw(address indexed user, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientStake(uint256 requested, uint256 available);
    error NotAuthorised();
    error ContractPaused();
    error NoPendingRewards();
    error InsufficientRewardBalance(uint256 required, uint256 available);

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime       = lastTimeRewardApplicable();
        if (account != address(0)) {
            pendingRewards[account]        = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param _timbsToken        TIMBS ERC-20 token address.
     * @param _rewardRatePerSecond Initial reward rate (TIMBS wei per second).
     */
    constructor(address _timbsToken, uint256 _rewardRatePerSecond)
        Ownable(msg.sender)
    {
        if (_timbsToken == address(0)) revert ZeroAddress();
        timbsToken          = IERC20(_timbsToken);
        rewardRatePerSecond = _rewardRatePerSecond;
        rewardNotifiers[msg.sender] = true;
    }

    // ─── View: Reward Calculation ─────────────────────────────────────────────

    /**
     * @notice Returns the applicable timestamp for reward accrual.
     *         Caps at periodFinish so rewards stop after the period ends.
     */
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /**
     * @notice Returns cumulative TIMBS earned per staked TIMBS since deploy.
     */
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + (
            (lastTimeRewardApplicable() - lastUpdateTime)
                * rewardRatePerSecond
                * 1e18
                / totalStaked
        );
    }

    /**
     * @notice Returns total TIMBS earned (pending + unsnapshotted) for `account`.
     */
    function earned(address account) public view returns (uint256) {
        return (
            stakedBalance[account]
                * (rewardPerToken() - userRewardPerTokenPaid[account])
                / 1e18
        ) + pendingRewards[account];
    }

    /**
     * @notice Estimated annual yield for `account` at current rate.
     *         Informational — actual yield depends on total staked changing.
     */
    function estimatedAPR() external view returns (uint256 aprBps) {
        if (totalStaked == 0) return 0;
        // annualRewards / totalStaked * 10000 (basis points)
        uint256 annualRewards = rewardRatePerSecond * 365 days;
        aprBps = (annualRewards * 10_000) / totalStaked;
    }

    // ─── Stake ────────────────────────────────────────────────────────────────

    /**
     * @notice Stake TIMBS to start earning rewards.
     * @dev No unique stake IDs — adds to accumulated balance.
     *      Caller must approve this contract before calling.
     * @param amount TIMBS amount to stake (18 decimals).
     */
    function stake(uint256 amount)
        external
        nonReentrant
        whenNotPaused
        updateReward(msg.sender)
    {
        if (amount == 0) revert ZeroAmount();

        stakedBalance[msg.sender] += amount;
        totalStaked               += amount;

        timbsToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    // ─── Unstake ──────────────────────────────────────────────────────────────

    /**
     * @notice Reduce or fully withdraw staked TIMBS.
     * @dev Collateral ownership verified: msg.sender can only unstake
     *      their own balance. No delegate unstake.
     *      Pending rewards are NOT auto-claimed — call claimRewards() separately
     *      or use exit() for a combined unstake + claim.
     * @param amount TIMBS amount to unstake.
     */
    function unstake(uint256 amount)
        external
        nonReentrant
        whenNotPaused
        updateReward(msg.sender)
    {
        if (amount == 0) revert ZeroAmount();
        if (amount > stakedBalance[msg.sender]) {
            revert InsufficientStake(amount, stakedBalance[msg.sender]);
        }

        stakedBalance[msg.sender] -= amount;
        totalStaked               -= amount;

        timbsToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    // ─── Claim Rewards ────────────────────────────────────────────────────────

    /**
     * @notice Claim all pending TIMBS rewards.
     * @dev Reward balance checked before transfer —
     *      reverts if contract doesn't have enough TIMBS to pay.
     */
    function claimRewards()
        external
        nonReentrant
        whenNotPaused
        updateReward(msg.sender)
    {
        uint256 reward = pendingRewards[msg.sender];
        if (reward == 0) revert NoPendingRewards();

        uint256 contractBalance = timbsToken.balanceOf(address(this)) - totalStaked;
        if (reward > contractBalance) {
            revert InsufficientRewardBalance(reward, contractBalance);
        }

        pendingRewards[msg.sender] = 0;
        timbsToken.safeTransfer(msg.sender, reward);

        emit RewardsClaimed(msg.sender, reward);
    }

    /**
     * @notice Unstake all TIMBS and claim all pending rewards in one tx.
     */
    function exit()
        external
        nonReentrant
        whenNotPaused
        updateReward(msg.sender)
    {
        uint256 staked = stakedBalance[msg.sender];
        uint256 reward = pendingRewards[msg.sender];

        if (staked > 0) {
            stakedBalance[msg.sender] = 0;
            totalStaked              -= staked;
            timbsToken.safeTransfer(msg.sender, staked);
            emit Unstaked(msg.sender, staked);
        }

        if (reward > 0) {
            uint256 contractBalance = timbsToken.balanceOf(address(this)) - totalStaked;
            if (reward <= contractBalance) {
                pendingRewards[msg.sender] = 0;
                timbsToken.safeTransfer(msg.sender, reward);
                emit RewardsClaimed(msg.sender, reward);
            }
            // If insufficient rewards, skip claim silently — stake still returned
        }
    }

    // ─── Owner: Reward Funding ────────────────────────────────────────────────

    /**
     * @notice Fund the reward pool and set the distribution period.
     * @dev Called by owner or TimbTreasury (after buyback) to deposit
     *      TIMBS and activate a new reward period.
     *
     *      If a period is still active, remaining rewards are rolled
     *      into the new period before recalculating the rate.
     *
     * @param amount   TIMBS amount to add to reward pool.
     * @param duration Duration in seconds over which to distribute.
     */
    function notifyRewardAmount(uint256 amount, uint256 duration)
        external
        nonReentrant
        updateReward(address(0))
    {
        if (!rewardNotifiers[msg.sender] && msg.sender != owner()) {
            revert NotAuthorised();
        }
        if (amount == 0)   revert ZeroAmount();
        if (duration == 0) revert ZeroAmount();

        timbsToken.safeTransferFrom(msg.sender, address(this), amount);

        if (block.timestamp < periodFinish) {
            // Roll remaining rewards into new period
            uint256 remaining    = periodFinish - block.timestamp;
            uint256 leftover     = remaining * rewardRatePerSecond;
            rewardRatePerSecond  = (amount + leftover) / duration;
        } else {
            rewardRatePerSecond = amount / duration;
        }

        lastUpdateTime = block.timestamp;
        periodFinish   = block.timestamp + duration;

        emit RewardNotified(msg.sender, amount, duration);
    }

    /**
     * @notice Update the reward rate directly (owner only).
     * @dev Snapshots accumulator before changing rate.
     *      Use notifyRewardAmount() for funding + rate update in one call.
     */
    function setRewardRate(uint256 _ratePerSecond)
        external
        onlyOwner
        updateReward(address(0))
    {
        rewardRatePerSecond = _ratePerSecond;
        emit RewardRateSet(_ratePerSecond);
    }

    // ─── Owner: Config ────────────────────────────────────────────────────────

    /**
     * @notice Set TimbTreasury address and authorise it as a reward notifier.
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        // Deauthorise old treasury if set
        if (treasury != address(0)) rewardNotifiers[treasury] = false;
        treasury = _treasury;
        rewardNotifiers[_treasury] = true;
        emit TreasurySet(_treasury);
        emit RewardNotifierSet(_treasury, true);
    }

    /**
     * @notice Add or remove a reward notifier address.
     */
    function setRewardNotifier(address notifier, bool authorised)
        external
        onlyOwner
    {
        if (notifier == address(0)) revert ZeroAddress();
        rewardNotifiers[notifier] = authorised;
        emit RewardNotifierSet(notifier, authorised);
    }

    /**
     * @notice Emergency pause — halts stake/unstake/claim.
     */
    function pause()   external onlyOwner { paused = true;  emit Paused(msg.sender); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(msg.sender); }

    /**
     * @notice Emergency withdraw — allows user to recover staked TIMBS
     *         even when paused. Forfeits pending rewards.
     * @dev Safety valve only. Rewards are NOT paid on emergency withdraw.
     *      updateReward settles the global accumulator at the CURRENT totalStaked
     *      before it shrinks below — otherwise the elapsed reward window is
     *      retroactively re-divided across the remaining (fewer) stakers,
     *      over-crediting them and over-draining the reward reserve.
     */
    function emergencyWithdraw() external nonReentrant updateReward(msg.sender) {
        uint256 staked = stakedBalance[msg.sender];
        if (staked == 0) revert ZeroAmount();

        stakedBalance[msg.sender]        = 0;
        pendingRewards[msg.sender]       = 0;
        userRewardPerTokenPaid[msg.sender] = 0;
        totalStaked                      -= staked;

        timbsToken.safeTransfer(msg.sender, staked);
        emit EmergencyWithdraw(msg.sender, staked);
    }

    /**
     * @notice Owner can recover ERC20 tokens accidentally sent to this contract.
     * @dev Cannot recover staked TIMBS (protected by totalStaked check).
     */
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        if (token == address(timbsToken)) {
            // Only allow recovery of reward TIMBS above totalStaked
            uint256 recoverable = timbsToken.balanceOf(address(this)) - totalStaked;
            if (amount > recoverable) revert InsufficientRewardBalance(amount, recoverable);
        }
        IERC20(token).safeTransfer(owner(), amount);
    }
}
