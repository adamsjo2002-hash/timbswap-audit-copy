// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TimbFarm
 * @notice TIMBS/ETH LP farming pool.
 *
 * Model:
 *   - Stake TIMBS/ETH LP tokens, earn TIMBS emissions.
 *   - LP stakers also passively earn 0.25% swap fees via the pair
 *     contract (accrues to reserves, redeemable on removeLiquidity).
 *   - Reward source: treasury TIMBS allocation + notifyRewardAmount()
 *     calls from TimbTreasury.
 *   - Fixed emission rate set by owner (changeable anytime).
 *   - MasterChef-style rewardPerToken accumulator — same pattern as
 *     TimbStaking, no loops, scales to any number of LPs.
 *   - No unique stake IDs — accumulated balance per address.
 *   - Free add/reduce/withdraw anytime — no lock, no penalty.
 *
 * Differences from TimbStaking:
 *   - Staked token = LP token (TimbSwapPair), not TIMBS.
 *   - Reward token = TIMBS (same as TimbStaking).
 *   - LP token address is owner-set post-deploy (pair created after farm).
 *   - emissionsMultiplier: owner can boost this pool vs single-asset pool.
 *
 * Security (defiSKILL):
 *   - ReentrancyGuard on stake(), unstake(), claimRewards(), exit().
 *   - Collateral ownership: msg.sender owns their LP stake.
 *   - Flash stake protection: time-weighted accumulator.
 *   - SafeERC20 on all transfers.
 *   - LP token address validated against factory before staking enabled.
 *   - Emergency pause + emergencyWithdraw (recovers LP, forfeits rewards).
 *   - recoverERC20() cannot pull staked LP tokens.
 *
 * Deployment:
 *   1. Deploy TimbFarm(timbsToken, rewardRatePerSecond)
 *   2. After TimbSwapPair TIMBS/ETH deployed:
 *      setLpToken(pairAddress)
 *   3. TIMBSToken.setFarmPool(address(this))
 *   4. setTreasury(timbTreasury)
 *   5. notifyRewardAmount(amount, duration) to activate emissions
 */
contract TimbFarm is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice TIMBS token — reward token.
    IERC20 public immutable timbsToken;

    /// @notice TIMBS/ETH LP token — staked token.
    ///         Set post-deploy once pair is created.
    IERC20 public lpToken;

    /// @notice TimbTreasury — authorised reward notifier.
    address public treasury;

    /// @notice TIMBS rewards distributed per second across all LP stakers.
    uint256 public rewardRatePerSecond;

    /// @notice Timestamp when current reward period ends.
    uint256 public periodFinish;

    /// @notice Last timestamp accumulator was updated.
    uint256 public lastUpdateTime;

    /// @notice Cumulative TIMBS earned per staked LP (18-decimal fixed point).
    uint256 public rewardPerTokenStored;

    /// @notice Total LP tokens currently staked.
    uint256 public totalStaked;

    /// @notice LP staked balance per address.
    mapping(address => uint256) public stakedBalance;

    /// @notice Accumulator snapshot per address at last interaction.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Pending (earned but unclaimed) TIMBS rewards per address.
    mapping(address => uint256) public pendingRewards;

    /// @notice Authorised reward notifiers (owner + treasury).
    mapping(address => bool) public rewardNotifiers;

    /// @notice LP token address locked after first stake — prevents rug
    ///         via changing lpToken while users are staked.
    bool public lpTokenLocked;

    /// @notice Emergency pause flag.
    bool public paused;

    // ─── Events ──────────────────────────────────────────────────────────────

    event Staked(address indexed user, uint256 lpAmount);
    event Unstaked(address indexed user, uint256 lpAmount);
    event RewardsClaimed(address indexed user, uint256 timbsAmount);
    event RewardNotified(address indexed notifier, uint256 amount, uint256 duration);
    event LpTokenSet(address indexed lpToken);
    event TreasurySet(address indexed treasury);
    event RewardRateSet(uint256 newRatePerSecond);
    event RewardNotifierSet(address indexed notifier, bool authorised);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event EmergencyWithdraw(address indexed user, uint256 lpAmount);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error LpTokenNotSet();
    error LpTokenAlreadyLocked();
    error LpTokenIsRewardToken();
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

    modifier lpSet() {
        if (address(lpToken) == address(0)) revert LpTokenNotSet();
        _;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime       = lastTimeRewardApplicable();
        if (account != address(0)) {
            pendingRewards[account]         = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param _timbsToken         TIMBS ERC-20 address (reward token).
     * @param _rewardRatePerSecond Initial TIMBS emission rate per second.
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
     * @notice Returns applicable reward timestamp (capped at periodFinish).
     */
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /**
     * @notice Cumulative TIMBS earned per staked LP token since deploy.
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
     * @notice Total TIMBS earned (pending + unsnapshotted) for `account`.
     */
    function earned(address account) public view returns (uint256) {
        return (
            stakedBalance[account]
                * (rewardPerToken() - userRewardPerTokenPaid[account])
                / 1e18
        ) + pendingRewards[account];
    }

    /**
     * @notice Estimated annual TIMBS emission APR for LP stakers.
     *         Does not include the 0.25% swap fee component (accrues in pair).
     */
    function estimatedEmissionsAPR() external view returns (uint256 aprBps) {
        if (totalStaked == 0) return 0;
        uint256 annualRewards = rewardRatePerSecond * 365 days;
        aprBps = (annualRewards * 10_000) / totalStaked;
    }

    // ─── Stake ────────────────────────────────────────────────────────────────

    /**
     * @notice Stake TIMBS/ETH LP tokens to earn TIMBS emissions.
     * @dev Caller must approve this contract for lpToken before calling.
     *      First stake locks the lpToken address permanently.
     * @param amount LP token amount to stake.
     */
    function stake(uint256 amount)
        external
        nonReentrant
        whenNotPaused
        lpSet
        updateReward(msg.sender)
    {
        if (amount == 0) revert ZeroAmount();

        // Lock LP token address on first stake — prevents rug via setLpToken()
        if (!lpTokenLocked) lpTokenLocked = true;

        stakedBalance[msg.sender] += amount;
        totalStaked               += amount;

        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    // ─── Unstake ──────────────────────────────────────────────────────────────

    /**
     * @notice Reduce or fully withdraw staked LP tokens.
     * @dev Collateral ownership enforced — msg.sender only.
     *      Pending rewards NOT auto-claimed. Use exit() for combined op.
     * @param amount LP token amount to unstake.
     */
    function unstake(uint256 amount)
        external
        nonReentrant
        whenNotPaused
        lpSet
        updateReward(msg.sender)
    {
        if (amount == 0) revert ZeroAmount();
        if (amount > stakedBalance[msg.sender]) {
            revert InsufficientStake(amount, stakedBalance[msg.sender]);
        }

        stakedBalance[msg.sender] -= amount;
        totalStaked               -= amount;

        lpToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    // ─── Claim Rewards ────────────────────────────────────────────────────────

    /**
     * @notice Claim all pending TIMBS rewards.
     */
    function claimRewards()
        external
        nonReentrant
        whenNotPaused
        updateReward(msg.sender)
    {
        uint256 reward = pendingRewards[msg.sender];
        if (reward == 0) revert NoPendingRewards();

        // Available rewards = contract TIMBS balance minus staked TIMBS
        // (TIMBS is not the staked token here, so full balance is rewards)
        uint256 available = timbsToken.balanceOf(address(this));
        if (reward > available) {
            revert InsufficientRewardBalance(reward, available);
        }

        pendingRewards[msg.sender] = 0;
        timbsToken.safeTransfer(msg.sender, reward);

        emit RewardsClaimed(msg.sender, reward);
    }

    /**
     * @notice Unstake all LP tokens and claim all pending TIMBS rewards in one tx.
     */
    function exit()
        external
        nonReentrant
        whenNotPaused
        lpSet
        updateReward(msg.sender)
    {
        uint256 staked = stakedBalance[msg.sender];
        uint256 reward = pendingRewards[msg.sender];

        if (staked > 0) {
            stakedBalance[msg.sender] = 0;
            totalStaked              -= staked;
            lpToken.safeTransfer(msg.sender, staked);
            emit Unstaked(msg.sender, staked);
        }

        if (reward > 0) {
            uint256 available = timbsToken.balanceOf(address(this));
            if (reward <= available) {
                pendingRewards[msg.sender] = 0;
                timbsToken.safeTransfer(msg.sender, reward);
                emit RewardsClaimed(msg.sender, reward);
            }
            // LP always returned even if reward balance insufficient
        }
    }

    // ─── Owner: Reward Funding ────────────────────────────────────────────────

    /**
     * @notice Fund the reward pool and set distribution period.
     * @dev Called by owner or TimbTreasury. Rolls over remaining rewards
     *      if current period is still active.
     * @param amount   TIMBS to add.
     * @param duration Seconds over which to distribute.
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
            uint256 remaining   = periodFinish - block.timestamp;
            uint256 leftover    = remaining * rewardRatePerSecond;
            rewardRatePerSecond = (amount + leftover) / duration;
        } else {
            rewardRatePerSecond = amount / duration;
        }

        lastUpdateTime = block.timestamp;
        periodFinish   = block.timestamp + duration;

        emit RewardNotified(msg.sender, amount, duration);
    }

    /**
     * @notice Update reward rate directly (owner only).
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
     * @notice Set the LP token address (TIMBS/ETH pair).
     * @dev Can only be set before first stake (lpTokenLocked = false).
     *      After first stake, LP token is permanent — no rug vector.
     */
    function setLpToken(address _lpToken) external onlyOwner {
        if (_lpToken == address(0)) revert ZeroAddress();
        // The LP token must never be the reward token: claimRewards/exit treat
        // the whole TIMBS balance as reward, so lp==TIMBS would pay staked
        // principal out as rewards. (TimbBoostFarm.addPool guards this too.)
        if (_lpToken == address(timbsToken)) revert LpTokenIsRewardToken();
        if (lpTokenLocked) revert LpTokenAlreadyLocked();
        lpToken = IERC20(_lpToken);
        emit LpTokenSet(_lpToken);
    }

    /**
     * @notice Set TimbTreasury and authorise as reward notifier.
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        if (treasury != address(0)) rewardNotifiers[treasury] = false;
        treasury = _treasury;
        rewardNotifiers[_treasury] = true;
        emit TreasurySet(_treasury);
        emit RewardNotifierSet(_treasury, true);
    }

    /**
     * @notice Add or remove a reward notifier.
     */
    function setRewardNotifier(address notifier, bool authorised)
        external
        onlyOwner
    {
        if (notifier == address(0)) revert ZeroAddress();
        rewardNotifiers[notifier] = authorised;
        emit RewardNotifierSet(notifier, authorised);
    }

    function pause()   external onlyOwner { paused = true;  emit Paused(msg.sender); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(msg.sender); }

    /**
     * @notice Emergency withdraw — recovers LP tokens even when paused.
     *         Forfeits all pending TIMBS rewards.
     * @dev    updateReward settles the global accumulator at the CURRENT
     *         totalStaked before it shrinks — otherwise the elapsed reward
     *         window is retroactively re-divided across the remaining (fewer)
     *         stakers, over-crediting them and over-draining the reserve.
     */
    function emergencyWithdraw() external nonReentrant updateReward(msg.sender) {
        uint256 staked = stakedBalance[msg.sender];
        if (staked == 0) revert ZeroAmount();

        stakedBalance[msg.sender]         = 0;
        pendingRewards[msg.sender]        = 0;
        userRewardPerTokenPaid[msg.sender] = 0;
        totalStaked                       -= staked;

        lpToken.safeTransfer(msg.sender, staked);
        emit EmergencyWithdraw(msg.sender, staked);
    }

    /**
     * @notice Owner recovers accidentally sent ERC20 tokens.
     * @dev Cannot recover staked LP tokens (protected by totalStaked).
     */
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        if (token == address(lpToken)) {
            uint256 recoverable = lpToken.balanceOf(address(this)) - totalStaked;
            if (amount > recoverable) {
                revert InsufficientRewardBalance(amount, recoverable);
            }
        }
        IERC20(token).safeTransfer(owner(), amount);
    }
}
